// SPDX-License-Identifier: GPL-3.0-or-later
#include "NetworkService.hpp"
#include "NetworkServiceState.hpp"
#include <chrono>
#include <iostream>
#include <ctime>
#include <SystemConfiguration/SystemConfiguration.h>
#include <dlfcn.h>
#include <net/if.h>
#include <unistd.h>
#include <cctype>
#include <cstdio>
#include <vector>
#include <set>

namespace horndis {
namespace {
// Apple's configd bridge SPI is not in the public SDK. Resolve it at runtime:
// an unavailable backend must not prevent the existing feth path from working.
struct BridgeAPI {
    SCNetworkInterfaceRef (*create)(SCPreferencesRef) =
        reinterpret_cast<decltype(create)>(dlsym(RTLD_DEFAULT, "SCBridgeInterfaceCreate"));
    CFArrayRef (*copyAll)(SCPreferencesRef) =
        reinterpret_cast<decltype(copyAll)>(dlsym(RTLD_DEFAULT, "SCBridgeInterfaceCopyAll"));
    Boolean (*remove)(SCNetworkInterfaceRef) =
        reinterpret_cast<decltype(remove)>(dlsym(RTLD_DEFAULT, "SCBridgeInterfaceRemove"));
    CFDictionaryRef (*options)(SCNetworkInterfaceRef) =
        reinterpret_cast<decltype(options)>(dlsym(RTLD_DEFAULT, "SCBridgeInterfaceGetOptions"));
    Boolean (*setOptions)(SCNetworkInterfaceRef, CFDictionaryRef) =
        reinterpret_cast<decltype(setOptions)>(dlsym(RTLD_DEFAULT, "SCBridgeInterfaceSetOptions"));
    explicit operator bool() const { return create && copyAll && remove && options && setOptions; }
};
constexpr auto kOwner = "io.github.noahhhi.horndis.network-v1";
std::string stringValue(CFStringRef value) {
    char buffer[256]{};
    if (!value || CFGetTypeID(value) != CFStringGetTypeID() ||
        !CFStringGetCString(value, buffer, sizeof(buffer), kCFStringEncodingUTF8)) return {};
    return buffer;
}
bool owned(CFDictionaryRef options) {
    return options && CFGetTypeID(options) == CFDictionaryGetTypeID() &&
        stringValue(static_cast<CFStringRef>(CFDictionaryGetValue(options, CFSTR("HoRNDISOwner")))) == kOwner;
}
// Refuse to attach to or delete a bridge with any existing member, including
// members missing from the stored bridge configuration.
bool emptyBridge(const std::string& name) {
    if (!isBridgeName(name)) return false;
    if (!if_nametoindex(name.c_str())) return true;
    const std::string command = "/sbin/ifconfig " + name;
    FILE* output = popen(command.c_str(), "r");
    if (!output) return false;
    bool empty = true;
    char line[1024];
    while (fgets(line, sizeof(line), output)) {
        if (std::string(line).find("member:") != std::string::npos) empty = false;
    }
    return pclose(output) == 0 && empty;
}
bool safeMemberApply(SCPreferencesRef prefs) {
    auto runtime = if_nameindex();
    if (!runtime) return false;
    bool safe = true;
    for (auto entry = runtime; entry->if_index; ++entry) {
        const std::string name = entry->if_name;
        if (!isBridgeName(name) || name.size() > 8) continue;
        auto path = CFStringCreateWithFormat(nullptr, nullptr,
            CFSTR("/VirtualNetworkInterfaces/Bridge/%s"), name.c_str());
        if (!SCPreferencesPathGetValue(prefs, path)) safe = false;
        CFRelease(path);
    }
    if_freenameindex(runtime);
    return safe;
}
void identityLog(const std::string& message) {
    std::time_t now = std::time(nullptr); std::tm utc{}; char stamp[32]{};
    gmtime_r(&now, &utc); std::strftime(stamp, sizeof(stamp), "%Y-%m-%dT%H:%M:%SZ", &utc);
    std::cerr << "horndis: " << stamp << " network identity " << message << '\n';
}
bool configure(bool removing, std::string& name, std::string& error, const std::string& expectedMember = "") {
    using namespace networkstate;
    error.clear();
    BridgeAPI api;
    if (geteuid() != 0 || !api) { error = "network service configuration requires root and the macOS bridge API"; return false; }
    NetworkServiceJournal journal;
    CFHandle<SCPreferencesRef> prefs(SCPreferencesCreate(nullptr, CFSTR("HoRNDIS Userspace"), nullptr));
    if (!prefs || !SCPreferencesLock(prefs.get(), true)) { error = "cannot lock system network preferences"; return false; }
    CFHandle<CFDictionaryRef> previous(journal.copy(error));
    // Full uninstall can still clean a valid on-disk owned registration if its
    // checkpoint is corrupt; the secure clear step never follows links.
    if (!error.empty() && !removing) { SCPreferencesUnlock(prefs.get()); return false; }
    error.clear();
    CFHandle<CFDictionaryRef> beforeSets(copySets(prefs.get()));
    SCNetworkInterfaceRef bridge = nullptr;
    SCNetworkServiceRef service = nullptr;
    bool ok = false, changed = false, recovering = false, committed = false;
    std::string id, action = "reused", positionReport;
    CFDictionaryRef history = preferredHistory(prefs.get(), previous.get());
    CFDictionaryRef rawBridge = nullptr;
    auto rawBridges = dictionary(pathValue(prefs.get(), "/VirtualNetworkInterfaces/Bridge"));
    std::vector<const void*> bridgeKeys(rawBridges ? CFDictionaryGetCount(rawBridges) : 0);
    if (rawBridges) CFDictionaryGetKeysAndValues(rawBridges, bridgeKeys.data(), nullptr);
    for (auto key : bridgeKeys) {
        auto candidate = dictionary(CFDictionaryGetValue(rawBridges, key));
        auto options = dictionary(field(candidate, CFSTR("Options")));
        if (!owned(options)) continue;
        if (rawBridge) { error = "multiple owned network bridges; refusing ambiguous recovery"; break; }
        name = text(key); id = text(field(options, CFSTR("HoRNDISServiceID"))); rawBridge = candidate;
    }
    // Prefer an existing valid owned registration over an interrupted write-ahead
    // checkpoint. This also preserves the user's latest changes before shutdown.
    CFHandle<CFDictionaryRef> actual;
    auto materialize = [&]() {
        CFHandle<CFDictionaryRef> phase(capture(prefs.get(), name, id, true, error, expectedMember));
        if (!phase) return false;
        CFHandle<CFMutableDictionaryRef> pending(CFDictionaryCreateMutableCopy(nullptr, 0, phase.get()));
        auto historicalLocations = dictionary(field(history, CFSTR("Locations")));
        CFHandle<CFMutableDictionaryRef> locations(historicalLocations ? CFDictionaryCreateMutableCopy(nullptr, 0, historicalLocations)
            : CFDictionaryCreateMutable(nullptr, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks));
        CFDictionaryApplyFunction(dictionary(field(phase.get(), CFSTR("Locations"))), [](const void* key, const void* value, void* context) {
            CFDictionarySetValue(static_cast<CFMutableDictionaryRef>(context), key, value);
        }, locations.get());
        CFDictionarySetValue(pending.get(), CFSTR("Locations"), locations.get());
        if (!journal.save(pending.get(), error)) return false;
        if (changed && !SCPreferencesCommitChanges(prefs.get())) {
            std::string ignored; if (previous) journal.save(previous.get(), ignored); else journal.clear(ignored);
            return false;
        }
        committed = true;
        if (!SCPreferencesApplyChanges(prefs.get())) return false;
        changed = false; recovering = true; action = "restored";
        return true;
    };
    do {
        if (!error.empty()) break;
        if (rawBridge) {
            if (!isBridgeName(name) || !validServiceID(id)) { error = "owned bridge has no valid service identity"; break; }
            if (!emptyBridge(name)) { error = "owned bridge has existing members; leaving it unchanged"; break; }
            if (!removing) {
                CFHandle<CFDictionaryRef> repaired(repairNestedServiceTable(serviceConfiguration(prefs.get(), id), id, name));
                if (repaired) {
                    if (!setPath(prefs.get(), "/NetworkServices/" + id, repaired.get())) { error = "cannot repair new-service defaults"; break; }
                    changed = true; action = "repaired name and DHCP";
                }
            }
            if (history && (text(field(history, CFSTR("ServiceID"))) != id || text(field(history, CFSTR("BridgeName"))) != name)) {
                actual = CFHandle<CFDictionaryRef>(capture(prefs.get(), name, id, false, error, expectedMember));
                if (!actual) break;
                history = actual.get();
            }
        } else if (history) {
            name = text(field(history, CFSTR("BridgeName"))); id = text(field(history, CFSTR("ServiceID")));
        }
        if (!removing && history) {
            if (!restoreMetadata(prefs.get(), history, if_nametoindex(name.c_str()) != 0, changed, error)) break;
            recovering = changed || field(history, CFSTR("NeedsApply")) == kCFBooleanTrue;
            if (recovering) action = "restored";
            rawBridge = dictionary(pathValue(prefs.get(), "/VirtualNetworkInterfaces/Bridge/" + name));
        }
        if (!removing && rawBridge) {
            auto members = array(field(rawBridge, CFSTR("Interfaces")));
            if (!members) { error = "invalid owned bridge membership"; break; }
            if (CFArrayGetCount(members) != 0) {
                const auto member = CFArrayGetCount(members) == 1 ? text(CFArrayGetValueAtIndex(members, 0)) : "";
                const bool stale = !member.empty() && (member == expectedMember ||
                    (history && member == text(field(history, CFSTR("LastMember"))) && if_nametoindex(member.c_str()) == 0));
                if (!stale || !emptyBridge(name)) { error = "owned bridge has foreign configured members; leaving it unchanged"; break; }
                CFHandle<CFMutableDictionaryRef> updated(CFDictionaryCreateMutableCopy(nullptr, 0, rawBridge));
                CFHandle<CFArrayRef> empty(copyStrings({})); CFDictionarySetValue(updated.get(), CFSTR("Interfaces"), empty.get());
                if (!setPath(prefs.get(), "/VirtualNetworkInterfaces/Bridge/" + name, updated.get())) { error = "cannot detach stale owned member"; break; }
                changed = true;
            }
        }
        std::set<std::string> configuredNames;
        CFHandle<CFArrayRef> bridges(api.copyAll(prefs.get()));
        if (bridges) for (CFIndex i = 0; i < CFArrayGetCount(bridges.get()); ++i) {
            auto candidate = static_cast<SCNetworkInterfaceRef>(CFArrayGetValueAtIndex(bridges.get(), i));
            configuredNames.insert(stringValue(SCNetworkInterfaceGetBSDName(candidate)));
            if (owned(api.options(candidate))) {
                if (bridge) { error = "multiple owned network bridges; refusing ambiguous recovery"; break; }
                bridge = candidate; CFRetain(bridge);
            }
        }
        if (!error.empty()) break;
        // A validated raw owned registration is sufficient to protect our own
        // not-yet-materialized interface; unrelated runtime bridges still block.
        if (rawBridge && isBridgeName(name)) configuredNames.insert(name);
        if (!removing || bridge) {
            auto runtime = if_nameindex();
            if (!runtime) { error = "cannot enumerate runtime network interfaces"; break; }
            for (auto entry = runtime; entry->if_index; ++entry) {
                const std::string other = entry->if_name;
                if (isBridgeName(other) && other.size() <= 8 && !configuredNames.contains(other))
                    error = "unmanaged runtime bridge exists; refusing global bridge reconciliation";
            }
            if_freenameindex(runtime);
            if (!error.empty()) break;
        }
        if (removing) {
            if (bridge && !emptyBridge(name)) { error = "owned bridge has existing members; leaving it unchanged"; break; }
            if (!id.empty() && !removeServiceMetadata(prefs.get(), name, id, changed, error)) break;
            if (bridge) { if (!api.remove(bridge)) break; changed = true; }
            if (changed && (!SCPreferencesCommitChanges(prefs.get()) || !SCPreferencesApplyChanges(prefs.get()))) break;
            if (!journal.clear(error)) break;
            identityLog("removed uuid=" + (id.empty() ? "none" : id)); ok = true; break;
        }
        if (!bridge && !name.empty()) {
            // A restored registration may need configd to materialize its
            // interface before SPI can construct the corresponding object.
            if (!materialize()) break;
            for (int retry = 0; retry < 40 && !bridge; ++retry) {
                CFHandle<CFArrayRef> ready(api.copyAll(prefs.get()));
                if (ready) for (CFIndex i = 0; i < CFArrayGetCount(ready.get()); ++i) {
                    auto candidate = static_cast<SCNetworkInterfaceRef>(CFArrayGetValueAtIndex(ready.get(), i));
                    if (stringValue(SCNetworkInterfaceGetBSDName(candidate)) == name && owned(api.options(candidate))) {
                        bridge = candidate; CFRetain(bridge); break;
                    }
                }
                if (!bridge) usleep(50000);
            }
            if (!bridge) { error = "owned bridge recovery is waiting for SystemConfiguration; retained saved UUID"; break; }
        }
        if (!bridge) {
            // Refuse to duplicate an unmarked legacy service after migration.
            auto allServices = dictionary(SCPreferencesGetValue(prefs.get(), CFSTR("NetworkServices")));
            std::vector<const void*> values(allServices ? CFDictionaryGetCount(allServices) : 0);
            if (allServices) CFDictionaryGetKeysAndValues(allServices, nullptr, values.data());
            for (auto value : values) if (text(field(dictionary(value), CFSTR("UserDefinedName"))) == "HoRNDIS USB") error = "unmarked HoRNDIS service exists; recovery identity is required";
            if (!error.empty()) break;
            std::vector<SCNetworkInterfaceRef> skipped;
            for (int attempt = 0; attempt < 100; ++attempt) {
                auto candidate = api.create(prefs.get()); if (!candidate) break;
                auto candidateName = stringValue(SCNetworkInterfaceGetBSDName(candidate));
                if (isBridgeName(candidateName) && !if_nametoindex(candidateName.c_str())) { bridge = candidate; name = candidateName; break; }
                skipped.push_back(candidate);
            }
            for (auto candidate : skipped) { api.remove(candidate); CFRelease(candidate); }
            if (!bridge) break;
            changed = true; action = "created";
        }
        if (!id.empty()) {
            CFHandle<CFStringRef> identifier(CFStringCreateWithCString(nullptr, id.c_str(), kCFStringEncodingUTF8));
            service = SCNetworkServiceCopy(prefs.get(), identifier.get());
            if (!service && history && (changed || field(history, CFSTR("NeedsApply")) == kCFBooleanTrue || if_nametoindex(name.c_str()) == 0)) {
                // A boot-time missing interface is not proof that its UUID is
                // unusable. Materialize the saved registration before considering
                // a replacement, with a durable pending checkpoint for crashes.
                if (!materialize()) break;
                for (int retry = 0; retry < 40 && !service; ++retry) {
                    service = SCNetworkServiceCopy(prefs.get(), identifier.get());
                    if (!service) usleep(50000);
                }
                if (!service && if_nametoindex(name.c_str()) == 0) {
                    error = "saved bridge is not ready; retained original service UUID"; break;
                }
            }
        }
        if (service && (!SCNetworkServiceGetInterface(service) || stringValue(SCNetworkInterfaceGetBSDName(SCNetworkServiceGetInterface(service))) != name)) { error = "network service identity changed; leaving it unchanged"; break; }
        const auto oldID = id;
        if (!service) {
            CFHandle<SCNetworkServiceRef> fresh(SCNetworkServiceCreate(prefs.get(), bridge));
            if (!fresh) break;
            const bool needsDefaults = !serviceConfiguration(prefs.get(), id) && !dictionary(field(history, CFSTR("ServiceConfiguration")));
            if (needsDefaults ? !initializeFreshService(fresh.get(), error) : !SCNetworkServiceEstablishDefaultConfiguration(fresh.get())) break;
            const auto newID = text(SCNetworkServiceGetServiceID(fresh.get()));
            CFHandle<CFDictionaryRef> configuration(configurationForCreatedService(prefs.get(), id, newID, history, error));
            if (!configuration) break;
            if (!id.empty()) {
                if (!setPath(prefs.get(), "/NetworkServices/" + id, configuration.get())) break;
                CFHandle<CFStringRef> old(CFStringCreateWithCString(nullptr, id.c_str(), kCFStringEncodingUTF8));
                service = SCNetworkServiceCopy(prefs.get(), old.get());
                if (service) {
                    if (!SCNetworkServiceRemove(fresh.get())) break;
                    action = "restored";
                } else {
                    // Only a confirmed, owned unusable identity is retired. Its
                    // replacement is inserted into the old slot/anchor position.
                    if (!removeServiceMetadata(prefs.get(), name, id, changed, error) ||
                        !setPath(prefs.get(), "/NetworkServices/" + newID, configuration.get())) break;
                    service = fresh.release();
                    id = newID; action = "rebuilt";
                }
            } else {
                if (!setPath(prefs.get(), "/NetworkServices/" + newID, configuration.get())) break;
                service = fresh.release(); id = newID;
            }
            if (!service) break;
            changed = true; recovering = !oldID.empty();
        }
        auto existingOptions = api.options(bridge);
        if (!owned(existingOptions) || text(field(existingOptions, CFSTR("HoRNDISServiceID"))) != id) {
            CFHandle<CFMutableDictionaryRef> options(existingOptions ? CFDictionaryCreateMutableCopy(nullptr, 0, existingOptions) : CFDictionaryCreateMutable(nullptr, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks));
            CFHandle<CFStringRef> owner(CFStringCreateWithCString(nullptr, kOwner, kCFStringEncodingUTF8));
            CFHandle<CFStringRef> sid(CFStringCreateWithCString(nullptr, id.c_str(), kCFStringEncodingUTF8));
            CFDictionarySetValue(options.get(), CFSTR("HoRNDISOwner"), owner.get()); CFDictionarySetValue(options.get(), CFSTR("HoRNDISServiceID"), sid.get());
            if (!api.setOptions(bridge, options.get())) break; changed = true;
        }
        if (!placeInSets(prefs.get(), beforeSets.get(), history, oldID, service, recovering, changed, positionReport, error)) break;
        const bool apply = changed || (history && field(history, CFSTR("NeedsApply")) == kCFBooleanTrue) || if_nametoindex(name.c_str()) == 0;
        CFHandle<CFDictionaryRef> candidate(capture(prefs.get(), name, id, apply, error, expectedMember));
        if (!candidate) break;
        CFHandle<CFMutableDictionaryRef> pending(CFDictionaryCreateMutableCopy(nullptr, 0, candidate.get()));
        if (apply && history && text(field(history, CFSTR("ServiceID"))) != id) {
            CFHandle<CFMutableDictionaryRef> rollback(CFDictionaryCreateMutableCopy(nullptr, 0, history));
            CFDictionaryRemoveValue(rollback.get(), CFSTR("Previous"));
            CFDictionarySetValue(pending.get(), CFSTR("Previous"), rollback.get());
        }
        if (!journal.save(pending.get(), error)) break;
        if (changed && !SCPreferencesCommitChanges(prefs.get())) {
            std::string ignored; if (previous) journal.save(previous.get(), ignored); else journal.clear(ignored);
            break;
        }
        committed = true;
        if (apply && !SCPreferencesApplyChanges(prefs.get())) break;
        CFHandle<CFDictionaryRef> complete(capture(prefs.get(), name, id, false, error, expectedMember));
        if (!complete || !journal.save(complete.get(), error)) break;
        identityLog(action + " uuid=" + id + " bridge=" + name + (oldID != id ? " previous=" + oldID : "") + positionReport);
        ok = true;
    } while (false);
    if (!ok && error.empty()) error = std::string("cannot configure HoRNDIS network service: ") + SCErrorString(SCError());
    if (!ok && committed) identityLog("recovery pending uuid=" + id + " " + error);
    if (service) CFRelease(service);
    if (bridge) CFRelease(bridge);
    SCPreferencesUnlock(prefs.get());
    return ok;
}
}
bool isBridgeName(const std::string& name) {
    if (!name.starts_with("bridge") || name.size() <= 6 || name.size() >= IFNAMSIZ) return false;
    for (size_t i = 6; i < name.size(); ++i) if (!std::isdigit(static_cast<unsigned char>(name[i]))) return false;
    return true;
}
bool ensureNetworkService(std::string& bridgeName, std::string& error, const std::string& member) { return configure(false, bridgeName, error, member); }
void checkpointNetworkService(const std::string& bridge, const std::string& member, bool force) {
    using namespace networkstate;
    if (geteuid() != 0 || !isBridgeName(bridge)) return;
    static auto checked = std::chrono::steady_clock::time_point{};
    static std::string lastError;
    const auto now = std::chrono::steady_clock::now();
    if (!force && now - checked < std::chrono::seconds(1)) return;
    checked = now;
    std::string error;
    NetworkServiceJournal journal;
    CFHandle<SCPreferencesRef> prefs(SCPreferencesCreate(nullptr, CFSTR("HoRNDIS network checkpoint"), nullptr));
    if (!prefs || !SCPreferencesLock(prefs.get(), false)) return;
    // The same preferences lock covers capture+save and full uninstall+clear.
    // A shutting-down supervisor cannot recreate a checkpoint after uninstall.
    CFHandle<CFDictionaryRef> saved(journal.copy(error));
    if (error.empty() && saved && field(saved.get(), CFSTR("NeedsApply")) == kCFBooleanTrue) { SCPreferencesUnlock(prefs.get()); return; }
    if (error.empty()) {
        {
            auto config = dictionary(pathValue(prefs.get(), "/VirtualNetworkInterfaces/Bridge/" + bridge));
            auto options = dictionary(field(config, CFSTR("Options")));
            const auto id = text(field(options, CFSTR("HoRNDISServiceID")));
            auto members = array(field(config, CFSTR("Interfaces")));
            const bool safeMembers = members && (CFArrayGetCount(members) == 0 ||
                (CFArrayGetCount(members) == 1 && text(CFArrayGetValueAtIndex(members, 0)) == member));
            if (owned(options) && safeMembers && (!saved || (text(field(saved.get(), CFSTR("ServiceID"))) == id && text(field(saved.get(), CFSTR("BridgeName"))) == bridge))) {
                CFHandle<CFDictionaryRef> state(capture(prefs.get(), bridge, id, false, error, member));
                if (state) (void)journal.save(state.get(), error);
            } else error = "registration unavailable; retained last known UUID and position";
        }
    }
    SCPreferencesUnlock(prefs.get());
    if (!error.empty() && error != lastError) identityLog("checkpoint deferred: " + error);
    lastError = error;
}
bool setNetworkServiceMember(const std::string& bridgeName, const std::string& member,
                             bool attached, std::string& error) {
    if (geteuid() != 0 || !isBridgeName(bridgeName) || !member.starts_with("feth") ||
        member.size() <= 4 || member.size() >= IFNAMSIZ ||
        member.find_first_not_of("0123456789", 4) != std::string::npos) {
        error = "invalid owned network member"; return false;
    }
    auto prefs = SCPreferencesCreate(nullptr, CFSTR("HoRNDIS Userspace"), nullptr);
    if (!prefs) { error = "cannot open network preferences"; return false; }
    if (!SCPreferencesLock(prefs, true)) { CFRelease(prefs); error = "cannot lock network preferences"; return false; }
    auto path = CFStringCreateWithFormat(nullptr, nullptr, CFSTR("/VirtualNetworkInterfaces/Bridge/%s"), bridgeName.c_str());
    auto name = CFStringCreateWithCString(nullptr, member.c_str(), kCFStringEncodingUTF8);
    auto configuration = SCPreferencesPathGetValue(prefs, path);
    bool ok = false;
    do {
        if (!configuration || !owned(static_cast<CFDictionaryRef>(CFDictionaryGetValue(configuration, CFSTR("Options"))))) break;
        auto current = static_cast<CFArrayRef>(CFDictionaryGetValue(configuration, CFSTR("Interfaces")));
        if (!current || CFGetTypeID(current) != CFArrayGetTypeID()) break;
        const auto count = CFArrayGetCount(current);
        // Never replace someone else's configured members, even on our bridge.
        if (count > 1 || (count == 1 && !CFEqual(CFArrayGetValueAtIndex(current, 0), name))) break;
        if (count == (attached ? 1 : 0)) { ok = true; break; }
        if (!safeMemberApply(prefs) || (attached && !if_nametoindex(member.c_str()))) break;
        auto updated = CFDictionaryCreateMutableCopy(nullptr, 0, configuration);
        const void* values[] = {name};
        auto members = CFArrayCreate(nullptr, values, attached ? 1 : 0, &kCFTypeArrayCallBacks);
        // feth is representable by configd but is not offered by the bridge
        // member picker. Store its real BSD name in Apple's bridge schema;
        // runtime attachment remains an exclusively owned ifconfig operation.
        // Network Settings derives bridge status from this membership list.
        CFDictionarySetValue(updated, CFSTR("Interfaces"), members);
        ok = SCPreferencesPathSetValue(prefs, path, updated) &&
             SCPreferencesCommitChanges(prefs) && SCPreferencesApplyChanges(prefs);
        CFRelease(members); CFRelease(updated);
    } while (false);
    CFRelease(name); CFRelease(path); SCPreferencesUnlock(prefs); CFRelease(prefs);
    if (!ok) error = "cannot update owned bridge membership";
    return ok;
}
bool refreshNetworkService(const std::string& bridgeName, std::string& error) {
    if (geteuid() != 0 || !isBridgeName(bridgeName)) {
        error = "invalid network service refresh"; return false;
    }
    auto interfaces = SCNetworkInterfaceCopyAll();
    bool refreshed = false;
    if (interfaces) {
        for (CFIndex i = 0; i < CFArrayGetCount(interfaces); ++i) {
            auto interface = static_cast<SCNetworkInterfaceRef>(CFArrayGetValueAtIndex(interfaces, i));
            if (stringValue(SCNetworkInterfaceGetBSDName(interface)) == bridgeName) {
                refreshed = SCNetworkInterfaceForceConfigurationRefresh(interface); break;
            }
        }
        CFRelease(interfaces);
    }
    if (!refreshed) error = "cannot refresh the registered network service";
    return refreshed;
}
bool removeNetworkService(std::string& error) { std::string name; return configure(true, name, error); }
}
