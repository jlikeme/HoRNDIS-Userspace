// SPDX-License-Identifier: GPL-3.0-or-later
#include "NetworkServiceState.hpp"
#include <algorithm>
#include <cerrno>
#include <cctype>
#include <cstring>
#include <filesystem>
#include <fcntl.h>
#include <net/if.h>
#include <set>
#include <sys/stat.h>
#include <unistd.h>

namespace horndis {
RelativeServicePlacement placeOwnedService(const std::vector<std::string>& saved,
    const std::string& oldID, const std::string& newID, const std::vector<std::string>& current) {
    RelativeServicePlacement result;
    size_t oldPosition = 0;
    bool hadOld = false;
    for (const auto& id : current) {
        if (id == oldID) { if (!hadOld) oldPosition = result.order.size(); hadOld = true; }
        else if (id != newID) result.order.push_back(id);
    }
    size_t insertion = result.order.size();
    result.source = "no surviving anchors; appended";
    if (hadOld) { insertion = oldPosition; result.source = "current position"; }
    else if (const auto own = std::find(saved.begin(), saved.end(), oldID); own != saved.end()) {
        auto previous = result.order.end();
        auto next = result.order.end();
        for (auto i = own; i != saved.begin();) {
            --i; previous = std::find(result.order.begin(), result.order.end(), *i);
            if (previous != result.order.end()) break;
        }
        for (auto i = own + 1; i != saved.end(); ++i) {
            next = std::find(result.order.begin(), result.order.end(), *i);
            if (next != result.order.end()) break;
        }
        if (previous != result.order.end()) {
            insertion = static_cast<size_t>(previous - result.order.begin()) + 1;
            result.source = next != result.order.end() && previous >= next
                ? "anchors crossed; followed predecessor" : "nearest surviving predecessor";
        } else if (next != result.order.end()) {
            insertion = static_cast<size_t>(next - result.order.begin());
            result.source = "nearest surviving successor";
        }
    }
    result.order.insert(result.order.begin() + insertion, newID);
    return result;
}

namespace networkstate {
std::string text(CFTypeRef value) {
    if (!value || CFGetTypeID(value) != CFStringGetTypeID()) return {};
    auto string = static_cast<CFStringRef>(value);
    const auto size = CFStringGetMaximumSizeForEncoding(CFStringGetLength(string), kCFStringEncodingUTF8) + 1;
    if (size > 1024 * 1024) return {};
    std::vector<char> buffer(static_cast<size_t>(size));
    return CFStringGetCString(string, buffer.data(), size, kCFStringEncodingUTF8) ? buffer.data() : "";
}
CFDictionaryRef dictionary(CFTypeRef value) { return value && CFGetTypeID(value) == CFDictionaryGetTypeID() ? static_cast<CFDictionaryRef>(value) : nullptr; }
CFArrayRef array(CFTypeRef value) { return value && CFGetTypeID(value) == CFArrayGetTypeID() ? static_cast<CFArrayRef>(value) : nullptr; }
CFTypeRef field(CFDictionaryRef value, CFStringRef key) { return value ? CFDictionaryGetValue(value, key) : nullptr; }
std::vector<std::string> strings(CFArrayRef value) {
    std::vector<std::string> result;
    if (value) for (CFIndex i = 0; i < CFArrayGetCount(value); ++i) result.push_back(text(CFArrayGetValueAtIndex(value, i)));
    return result;
}
CFArrayRef copyStrings(const std::vector<std::string>& values) {
    auto result = CFArrayCreateMutable(nullptr, 0, &kCFTypeArrayCallBacks);
    for (const auto& value : values) {
        CFHandle<CFStringRef> string(CFStringCreateWithCString(nullptr, value.c_str(), kCFStringEncodingUTF8));
        CFArrayAppendValue(result, string.get());
    }
    return result;
}
CFTypeRef pathValue(SCPreferencesRef prefs, const std::string& path) {
    CFHandle<CFStringRef> name(CFStringCreateWithCString(nullptr, path.c_str(), kCFStringEncodingUTF8));
    return SCPreferencesPathGetValue(prefs, name.get());
}
bool setPath(SCPreferencesRef prefs, const std::string& path, CFDictionaryRef value) {
    CFHandle<CFStringRef> name(CFStringCreateWithCString(nullptr, path.c_str(), kCFStringEncodingUTF8));
    return SCPreferencesPathSetValue(prefs, name.get(), value);
}
bool removePath(SCPreferencesRef prefs, const std::string& path) {
    CFHandle<CFStringRef> name(CFStringCreateWithCString(nullptr, path.c_str(), kCFStringEncodingUTF8));
    return (!SCPreferencesPathGetValue(prefs, name.get()) && !SCPreferencesPathGetLink(prefs, name.get())) || SCPreferencesPathRemoveValue(prefs, name.get());
}
static bool identifier(const std::string& value) {
    if (value.size() != 36) return false;
    for (size_t i = 0; i < value.size(); ++i) {
        if (i == 8 || i == 13 || i == 18 || i == 23) { if (value[i] != '-') return false; }
        else if (!std::isxdigit(static_cast<unsigned char>(value[i]))) return false;
    }
    return true;
}
bool validServiceID(const std::string& value) { return identifier(value); }
CFDictionaryRef serviceConfiguration(SCPreferencesRef prefs, const std::string& id) {
    // Never let an empty ID resolve to the entire /NetworkServices table.
    return validServiceID(id) ? dictionary(pathValue(prefs, "/NetworkServices/" + id)) : nullptr;
}
bool initializeFreshService(SCNetworkServiceRef service, std::string& error) {
    if (!SCNetworkServiceEstablishDefaultConfiguration(service) ||
        !SCNetworkServiceSetName(service, CFSTR("HoRNDIS USB")) || !SCNetworkServiceSetEnabled(service, true)) {
        error = "cannot initialize the new HoRNDIS network service"; return false;
    }
    for (auto type : {kSCNetworkProtocolTypeIPv4, kSCNetworkProtocolTypeIPv6}) {
        CFHandle<SCNetworkProtocolRef> protocol(SCNetworkServiceCopyProtocol(service, type));
        if (!protocol) {
            if (!SCNetworkServiceAddProtocolType(service, type)) { error = "cannot add IP protocol"; return false; }
            protocol = CFHandle<SCNetworkProtocolRef>(SCNetworkServiceCopyProtocol(service, type));
        }
        const void* key = CFEqual(type, kSCNetworkProtocolTypeIPv4) ? kSCPropNetIPv4ConfigMethod : kSCPropNetIPv6ConfigMethod;
        const void* method = CFEqual(type, kSCNetworkProtocolTypeIPv4) ? kSCValNetIPv4ConfigMethodDHCP : kSCValNetIPv6ConfigMethodAutomatic;
        CFHandle<CFDictionaryRef> configuration(CFDictionaryCreate(nullptr, &key, &method, 1,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks));
        if (!protocol || !SCNetworkProtocolSetConfiguration(protocol.get(), configuration.get()) ||
            !SCNetworkProtocolSetEnabled(protocol.get(), true)) { error = "cannot enable IP configuration on the new service"; return false; }
    }
    return true;
}
CFDictionaryRef configurationForCreatedService(SCPreferencesRef prefs, const std::string& oldID,
    const std::string& newID, CFDictionaryRef history, std::string& error) {
    auto defaults = serviceConfiguration(prefs, newID);
    if (!defaults) { error = "new owned service has no default configuration"; return nullptr; }
    auto existing = serviceConfiguration(prefs, oldID);
    auto saved = existing ? existing : dictionary(field(history, CFSTR("ServiceConfiguration")));
    auto result = CFDictionaryCreateMutableCopy(nullptr, 0, saved ? saved : defaults);
    CFDictionarySetValue(result, CFSTR("Interface"), field(defaults, CFSTR("Interface")));
    return result;
}
static bool bridgeName(const std::string& value) {
    return value.starts_with("bridge") && value.size() > 6 && value.size() < IFNAMSIZ &&
        value.find_first_not_of("0123456789", 6) == std::string::npos;
}
static CFArrayRef order(CFDictionaryRef set) {
    auto network = dictionary(field(set, CFSTR("Network")));
    auto global = dictionary(field(network, CFSTR("Global")));
    return array(field(dictionary(field(global, CFSTR("IPv4"))), CFSTR("ServiceOrder")));
}
static bool member(CFDictionaryRef set, CFStringRef serviceID) {
    return field(dictionary(field(dictionary(field(set, CFSTR("Network"))), CFSTR("Service"))), serviceID) != nullptr;
}
static std::vector<CFStringRef> keys(CFDictionaryRef value) {
    std::vector<const void*> raw(value ? CFDictionaryGetCount(value) : 0);
    if (value) CFDictionaryGetKeysAndValues(value, raw.data(), nullptr);
    std::vector<CFStringRef> result;
    for (auto key : raw) if (key && CFGetTypeID(key) == CFStringGetTypeID()) result.push_back(static_cast<CFStringRef>(key));
    return result;
}
CFDictionaryRef repairNestedServiceTable(CFDictionaryRef configuration,
    const std::string& id, const std::string& bridge) {
    if (!validServiceID(id) || !configuration) return nullptr;
    CFHandle<CFStringRef> key(CFStringCreateWithCString(nullptr, id.c_str(), kCFStringEncodingUTF8));
    auto original = dictionary(field(configuration, key.get()));
    auto interface = dictionary(field(configuration, CFSTR("Interface")));
    if (!original || text(field(dictionary(field(original, CFSTR("Interface"))), CFSTR("DeviceName"))) != bridge ||
        text(field(interface, CFSTR("DeviceName"))) != bridge) return nullptr;
    auto result = CFDictionaryCreateMutableCopy(nullptr, 0, original);
    for (auto name : keys(configuration)) {
        if (!validServiceID(text(name))) CFDictionarySetValue(result, name, field(configuration, name));
    }
    const auto name = text(field(result, CFSTR("UserDefinedName")));
    if (name.empty() || name == text(field(interface, CFSTR("UserDefinedName"))) || name == text(field(original, CFSTR("UserDefinedName"))))
        CFDictionarySetValue(result, CFSTR("UserDefinedName"), CFSTR("HoRNDIS USB"));
    for (auto type : {CFSTR("IPv4"), CFSTR("IPv6")}) {
        auto value = dictionary(field(result, type));
        const auto method = text(field(value, CFSTR("ConfigMethod")));
        const bool ipv4 = CFEqual(type, CFSTR("IPv4"));
        // This migration repairs the broken automatic defaults, while retaining
        // a user's explicit manual IP configuration and all other valid fields.
        if (method.empty() || method == (ipv4 ? "DHCP" : "Automatic")) {
            CFHandle<CFMutableDictionaryRef> repaired(value ? CFDictionaryCreateMutableCopy(nullptr, 0, value)
                : CFDictionaryCreateMutable(nullptr, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks));
            CFDictionarySetValue(repaired.get(), CFSTR("ConfigMethod"), ipv4 ? CFSTR("DHCP") : CFSTR("Automatic"));
            CFDictionaryRemoveValue(repaired.get(), CFSTR("__INACTIVE__"));
            CFDictionarySetValue(result, type, repaired.get());
        }
    }
    return result;
}
static CFDictionaryRef repairedCheckpoint(CFDictionaryRef state, bool& repaired, unsigned depth = 0) {
    if (!state || depth > 1) return nullptr;
    CFHandle<CFMutableDictionaryRef> result(CFDictionaryCreateMutableCopy(nullptr, 0, state));
    CFHandle<CFDictionaryRef> configuration(repairNestedServiceTable(dictionary(field(state, CFSTR("ServiceConfiguration"))),
        text(field(state, CFSTR("ServiceID"))), text(field(state, CFSTR("BridgeName")))));
    if (configuration) { CFDictionarySetValue(result.get(), CFSTR("ServiceConfiguration"), configuration.get()); repaired = true; }
    if (auto previous = dictionary(field(state, CFSTR("Previous"))); previous && depth == 0) {
        CFHandle<CFDictionaryRef> fixed(repairedCheckpoint(previous, repaired, depth + 1));
        if (fixed) CFDictionarySetValue(result.get(), CFSTR("Previous"), fixed.get());
    }
    return result.release();
}
bool valid(CFDictionaryRef state, std::string& error) {
    error.clear();
    int version = 0;
    auto number = field(state, CFSTR("Version"));
    const auto bridge = text(field(state, CFSTR("BridgeName")));
    const auto service = text(field(state, CFSTR("ServiceID")));
    auto configuration = dictionary(field(state, CFSTR("ServiceConfiguration")));
    auto bridgeConfiguration = dictionary(field(state, CFSTR("BridgeConfiguration")));
    auto options = dictionary(field(bridgeConfiguration, CFSTR("Options")));
    auto locations = dictionary(field(state, CFSTR("Locations")));
    if (text(field(state, CFSTR("Owner"))) != kNetworkServiceOwner ||
        !number || CFGetTypeID(number) != CFNumberGetTypeID() ||
        !CFNumberGetValue(static_cast<CFNumberRef>(number), kCFNumberIntType, &version) || version != 1 ||
        !bridgeName(bridge) || !identifier(service) || !configuration || !locations || !options ||
        text(field(dictionary(field(configuration, CFSTR("Interface"))), CFSTR("DeviceName"))) != bridge ||
        text(field(options, CFSTR("HoRNDISOwner"))) != kNetworkServiceOwner ||
        text(field(options, CFSTR("HoRNDISServiceID"))) != service ||
        !array(field(bridgeConfiguration, CFSTR("Interfaces"))) ||
        CFArrayGetCount(array(field(bridgeConfiguration, CFSTR("Interfaces")))) != 0) {
        error = "invalid persistent HoRNDIS network identity; refusing to replace it"; return false;
    }
    for (auto key : keys(configuration)) if (validServiceID(text(key))) {
        error = "network identity contains a nested service table"; return false;
    }
    for (auto key : keys(locations)) {
        auto location = dictionary(field(locations, key));
        auto values = array(field(location, CFSTR("Order")));
        std::set<std::string> unique;
        if (!identifier(text(key)) || !location || !values || CFArrayGetCount(values) > 4096) { error = "invalid saved network location"; return false; }
        for (const auto& id : strings(values)) {
            if (id.empty() || id.size() > 256 || !unique.insert(id).second) { error = "invalid saved service order"; return false; }
        }
    }
    auto pending = field(state, CFSTR("NeedsApply"));
    if (pending && CFGetTypeID(pending) != CFBooleanGetTypeID()) { error = "invalid recovery phase"; return false; }
    auto previous = dictionary(field(state, CFSTR("Previous")));
    if (field(state, CFSTR("Previous")) && (!previous || field(previous, CFSTR("Previous")) || !valid(previous, error))) {
        error = "invalid previous network identity"; return false;
    }
    return true;
}
CFDictionaryRef preferredHistory(SCPreferencesRef prefs, CFDictionaryRef state) {
    auto previous = dictionary(field(state, CFSTR("Previous")));
    if (previous && field(state, CFSTR("NeedsApply")) == kCFBooleanTrue) {
        auto oldValue = dictionary(pathValue(prefs, "/NetworkServices/" + text(field(previous, CFSTR("ServiceID")))));
        auto nextValue = dictionary(pathValue(prefs, "/NetworkServices/" + text(field(state, CFSTR("ServiceID")))));
        if (oldValue && !nextValue && text(field(dictionary(field(oldValue, CFSTR("Interface"))), CFSTR("DeviceName"))) == text(field(previous, CFSTR("BridgeName")))) return previous;
    }
    return state;
}
CFDictionaryRef copySets(SCPreferencesRef prefs) {
    auto sets = dictionary(SCPreferencesGetValue(prefs, CFSTR("Sets")));
    return sets ? static_cast<CFDictionaryRef>(CFPropertyListCreateDeepCopy(nullptr, sets, kCFPropertyListImmutable))
                : CFDictionaryCreate(nullptr, nullptr, nullptr, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
}
CFDictionaryRef capture(SCPreferencesRef prefs, const std::string& bridge,
    const std::string& serviceID, bool needsApply, std::string& error, const std::string& memberName) {
    auto configuration = dictionary(pathValue(prefs, "/NetworkServices/" + serviceID));
    auto bridgeValue = dictionary(pathValue(prefs, "/VirtualNetworkInterfaces/Bridge/" + bridge));
    if (!configuration || !bridgeValue) { error = "owned network registration is not ready for checkpoint"; return nullptr; }
    CFHandle<CFMutableDictionaryRef> state(CFDictionaryCreateMutable(nullptr, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks));
    CFHandle<CFMutableDictionaryRef> normalized(CFDictionaryCreateMutableCopy(nullptr, 0, bridgeValue));
    CFHandle<CFArrayRef> empty(copyStrings({}));
    CFDictionarySetValue(normalized.get(), CFSTR("Interfaces"), empty.get());
    CFHandle<CFStringRef> owner(CFStringCreateWithCString(nullptr, kNetworkServiceOwner, kCFStringEncodingUTF8));
    CFHandle<CFStringRef> b(CFStringCreateWithCString(nullptr, bridge.c_str(), kCFStringEncodingUTF8));
    CFHandle<CFStringRef> s(CFStringCreateWithCString(nullptr, serviceID.c_str(), kCFStringEncodingUTF8));
    int v = 1; CFHandle<CFNumberRef> version(CFNumberCreate(nullptr, kCFNumberIntType, &v));
    CFDictionarySetValue(state.get(), CFSTR("Owner"), owner.get());
    CFDictionarySetValue(state.get(), CFSTR("Version"), version.get());
    CFDictionarySetValue(state.get(), CFSTR("BridgeName"), b.get());
    CFDictionarySetValue(state.get(), CFSTR("ServiceID"), s.get());
    CFDictionarySetValue(state.get(), CFSTR("ServiceConfiguration"), configuration);
    CFDictionarySetValue(state.get(), CFSTR("BridgeConfiguration"), normalized.get());
    CFDictionarySetValue(state.get(), CFSTR("NeedsApply"), needsApply ? kCFBooleanTrue : kCFBooleanFalse);
    CFHandle<CFStringRef> lastMember(CFStringCreateWithCString(nullptr, memberName.c_str(), kCFStringEncodingUTF8));
    CFDictionarySetValue(state.get(), CFSTR("LastMember"), lastMember.get());
    CFHandle<CFMutableDictionaryRef> locations(CFDictionaryCreateMutable(nullptr, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks));
    CFHandle<CFDictionaryRef> sets(copySets(prefs));
    for (auto key : keys(sets.get())) {
        auto set = dictionary(field(sets.get(), key));
        auto values = order(set);
        const auto ids = strings(values);
        if (!member(set, s.get()) && std::find(ids.begin(), ids.end(), serviceID) == ids.end()) continue;
        CFHandle<CFMutableDictionaryRef> location(CFDictionaryCreateMutable(nullptr, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks));
        auto name = field(set, CFSTR("UserDefinedName"));
        CFDictionarySetValue(location.get(), CFSTR("Name"), name && CFGetTypeID(name) == CFStringGetTypeID() ? name : CFSTR(""));
        CFDictionarySetValue(location.get(), CFSTR("Order"), values ? values : empty.get());
        CFDictionarySetValue(locations.get(), key, location.get());
    }
    CFDictionarySetValue(state.get(), CFSTR("Locations"), locations.get());
    if (!valid(state.get(), error)) return nullptr;
    return static_cast<CFDictionaryRef>(CFPropertyListCreateDeepCopy(nullptr, state.get(), kCFPropertyListImmutable));
}
bool restoreMetadata(SCPreferencesRef prefs, CFDictionaryRef state,
    bool runtimeBridgeExists, bool& changed, std::string& error) {
    if (!valid(state, error)) return false;
    const auto bridge = text(field(state, CFSTR("BridgeName")));
    const auto id = text(field(state, CFSTR("ServiceID")));
    auto service = dictionary(pathValue(prefs, "/NetworkServices/" + id));
    if (service && text(field(dictionary(field(service, CFSTR("Interface"))), CFSTR("DeviceName"))) != bridge) {
        error = "saved service UUID now belongs to another interface; leaving it unchanged"; return false;
    }
    auto existing = dictionary(pathValue(prefs, "/VirtualNetworkInterfaces/Bridge/" + bridge));
    auto options = dictionary(field(existing, CFSTR("Options")));
    if (existing && (text(field(options, CFSTR("HoRNDISOwner"))) != kNetworkServiceOwner ||
                     text(field(options, CFSTR("HoRNDISServiceID"))) != id)) {
        error = "saved bridge name is used by another configuration; leaving it unchanged"; return false;
    }
    if (!existing) {
        if (runtimeBridgeExists) { error = "saved bridge name has an unmanaged runtime interface; refusing adoption"; return false; }
        if (!setPath(prefs, "/VirtualNetworkInterfaces/Bridge/" + bridge,
                     dictionary(field(state, CFSTR("BridgeConfiguration"))))) { error = "cannot restore owned bridge registration"; return false; }
        changed = true;
    }
    if (!service) {
        if (!setPath(prefs, "/NetworkServices/" + id, dictionary(field(state, CFSTR("ServiceConfiguration"))))) {
            error = "cannot restore owned service UUID"; return false;
        }
        changed = true;
    }
    return true;
}
bool removeServiceMetadata(SCPreferencesRef prefs, const std::string& bridge,
    const std::string& id, bool& changed, std::string& error) {
    if (!identifier(id)) { error = "invalid owned service UUID"; return false; }
    auto value = dictionary(pathValue(prefs, "/NetworkServices/" + id));
    if (value && text(field(dictionary(field(value, CFSTR("Interface"))), CFSTR("DeviceName"))) != bridge) {
        error = "owned service identity changed; refusing cleanup"; return false;
    }
    CFHandle<CFDictionaryRef> sets(copySets(prefs));
    CFHandle<CFStringRef> sid(CFStringCreateWithCString(nullptr, id.c_str(), kCFStringEncodingUTF8));
    for (auto key : keys(sets.get())) {
        const auto setID = text(key);
        auto set = dictionary(field(sets.get(), key));
        if (member(set, sid.get())) {
            if (!removePath(prefs, "/Sets/" + setID + "/Network/Service/" + id)) { error = "cannot remove owned location membership"; return false; }
            changed = true;
        }
        auto original = strings(order(set));
        auto updated = original; updated.erase(std::remove(updated.begin(), updated.end(), id), updated.end());
        if (updated != original) {
            CFHandle<SCNetworkSetRef> location(SCNetworkSetCopy(prefs, key));
            CFHandle<CFArrayRef> values(copyStrings(updated));
            if (!location || !SCNetworkSetSetServiceOrder(location.get(), values.get())) { error = "cannot remove owned service from order"; return false; }
            changed = true;
        }
    }
    if (value) { if (!removePath(prefs, "/NetworkServices/" + id)) { error = "cannot remove owned service metadata"; return false; } changed = true; }
    return true;
}
bool placeInSets(SCPreferencesRef prefs, CFDictionaryRef beforeSets, CFDictionaryRef history,
    const std::string& oldID, SCNetworkServiceRef service, bool recovering,
    bool& changed, std::string& report, std::string& error) {
    const auto newID = text(SCNetworkServiceGetServiceID(service));
    auto saved = dictionary(field(history, CFSTR("Locations")));
    CFHandle<CFArrayRef> all(SCNetworkSetCopyAll(prefs));
    CFHandle<SCNetworkSetRef> current(SCNetworkSetCopyCurrent(prefs));
    if (!all || CFArrayGetCount(all.get()) == 0 || !current) {
        error = "network location is not ready; preserved saved identity"; return false;
    }
    bool anySavedSet = false;
    if (all) for (CFIndex i = 0; i < CFArrayGetCount(all.get()); ++i) {
        auto set = static_cast<SCNetworkSetRef>(CFArrayGetValueAtIndex(all.get(), i));
        if (field(saved, SCNetworkSetGetSetID(set))) anySavedSet = true;
    }
    CFHandle<CFStringRef> old(CFStringCreateWithCString(nullptr, oldID.c_str(), kCFStringEncodingUTF8));
    bool changedIdentity = !oldID.empty() && oldID != newID;
    if (all) for (CFIndex i = 0; i < CFArrayGetCount(all.get()); ++i) {
        auto set = static_cast<SCNetworkSetRef>(CFArrayGetValueAtIndex(all.get(), i));
        auto setID = SCNetworkSetGetSetID(set);
        auto before = dictionary(field(beforeSets, setID));
        const auto beforeOrder = strings(order(before));
        const bool belonged = !oldID.empty() && (member(before, old.get()) || std::find(beforeOrder.begin(), beforeOrder.end(), oldID) != beforeOrder.end());
        auto remembered = dictionary(field(saved, setID));
        if (!remembered && recovering) {
            const auto name = text(SCNetworkSetGetName(set));
            CFDictionaryRef matching = nullptr;
            for (auto key : keys(saved)) {
                auto candidate = dictionary(field(saved, key));
                if (!name.empty() && text(field(candidate, CFSTR("Name"))) == name && !field(beforeSets, key)) {
                    if (matching) { matching = nullptr; break; }
                    matching = candidate;
                }
            }
            remembered = matching;
        }
        const bool first = !history && oldID.empty() && current && CFEqual(current.get(), set);
        // Existing valid services respect the user's current location membership.
        const bool restore = recovering && (remembered || (saved && CFDictionaryGetCount(saved) > 0 && !anySavedSet && current && CFEqual(current.get(), set)));
        if (!belonged && !first && !restore) continue;
        if (changedIdentity && member(before, old.get()) && !removePath(prefs, "/Sets/" + text(setID) + "/Network/Service/" + oldID)) {
            error = "cannot retire owned location membership"; return false;
        }
        CFHandle<CFArrayRef> members(SCNetworkSetCopyServices(set));
        bool included = false;
        if (members) for (CFIndex j = 0; j < CFArrayGetCount(members.get()); ++j)
            if (text(SCNetworkServiceGetServiceID(static_cast<SCNetworkServiceRef>(CFArrayGetValueAtIndex(members.get(), j)))) == newID) included = true;
        if (!included) {
            if (!SCNetworkSetAddService(set, service)) { error = "cannot add owned service to network location"; return false; }
            changed = true;
        }
        if (!recovering && !changedIdentity && !first && included) continue;
        auto reference = beforeOrder;
        if (!order(before)) {
            auto automatic = SCNetworkSetGetServiceOrder(set);
            if (!automatic) {
                if (first) { error = "cannot determine existing service order for default placement"; return false; }
                continue; // retain an unspecified order as unspecified
            }
            reference = strings(automatic);
            reference.erase(std::remove(reference.begin(), reference.end(), newID), reference.end());
        }
        auto desired = placeOwnedService(strings(array(field(remembered, CFSTR("Order")))), oldID, newID, reference);
        // With no previous identity or anchors, placeOwnedService appends the
        // new entry while preserving the existing services' relative ordering.
        if (first) desired.source = "initial default: appended";
        if (desired.order != strings(SCNetworkSetGetServiceOrder(set))) {
            CFHandle<CFArrayRef> values(copyStrings(desired.order));
            if (!SCNetworkSetSetServiceOrder(set, values.get())) { error = "cannot restore owned service position"; return false; }
            if (strings(SCNetworkSetGetServiceOrder(set)) != desired.order) { error = "service position readback differs; leaving preferences uncommitted"; return false; }
            changed = true;
        }
        if (recovering || changedIdentity || first) report += " location=" + text(setID) + " position=" + desired.source;
    }
    return true;
}
}

namespace {
constexpr const char* kJournalFile = "network-service.plist";
constexpr size_t kMaximumJournal = 1024 * 1024;
struct Descriptor { int value; ~Descriptor() { if (value >= 0) close(value); } };
bool regularPrivate(int descriptor, uid_t owner, std::string& error) {
    struct stat metadata{};
    if (fstat(descriptor, &metadata) != 0 || !S_ISREG(metadata.st_mode) || metadata.st_uid != owner ||
        metadata.st_nlink != 1 || (metadata.st_mode & 077) != 0 || metadata.st_size > static_cast<off_t>(kMaximumJournal)) {
        error = "network identity file must be private, regular and owned by the supervisor"; return false;
    }
    return true;
}
}
NetworkServiceJournal::NetworkServiceJournal(std::string directory, uid_t owner) : directory_(std::move(directory)), owner_(owner) {}
int NetworkServiceJournal::openDirectory(bool create, std::string& error) const {
    const std::filesystem::path path(directory_);
    Descriptor parent{open(path.parent_path().c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)};
    struct stat metadata{};
    if (parent.value < 0 || fstat(parent.value, &metadata) != 0 || metadata.st_uid != owner_ || (metadata.st_mode & 022) != 0) {
        error = "unsafe network identity parent directory"; return -1;
    }
    if (create && mkdirat(parent.value, path.filename().c_str(), 0700) != 0 && errno != EEXIST) {
        error = "cannot create private network identity directory"; return -1;
    }
    int descriptor = openat(parent.value, path.filename().c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (descriptor < 0) { if (errno != ENOENT) error = "cannot open private network identity directory"; return -1; }
    if (fstat(descriptor, &metadata) != 0 || metadata.st_uid != owner_ || (metadata.st_mode & 022) != 0) {
        close(descriptor); error = "unsafe network identity directory ownership or permissions"; return -1;
    }
    return descriptor;
}
CFDictionaryRef NetworkServiceJournal::copy(std::string& error, bool* repaired) const {
    error.clear();
    if (repaired) *repaired = false;
    Descriptor directory{openDirectory(false, error)};
    if (directory.value < 0) return nullptr;
    Descriptor file{openat(directory.value, kJournalFile, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)};
    if (file.value < 0) { if (errno != ENOENT) error = "cannot open protected network identity"; return nullptr; }
    if (!regularPrivate(file.value, owner_, error)) return nullptr;
    std::vector<UInt8> bytes;
    UInt8 buffer[4096];
    for (;;) {
        auto count = read(file.value, buffer, sizeof(buffer));
        if (count < 0 && errno == EINTR) continue;
        if (count < 0 || bytes.size() + static_cast<size_t>(std::max<ssize_t>(count, 0)) > kMaximumJournal) { error = "cannot read bounded network identity"; return nullptr; }
        if (count == 0) break;
        bytes.insert(bytes.end(), buffer, buffer + count);
    }
    CFHandle<CFDataRef> data(CFDataCreate(nullptr, bytes.data(), bytes.size()));
    CFHandle<CFPropertyListRef> value(CFPropertyListCreateWithData(nullptr, data.get(), kCFPropertyListImmutable, nullptr, nullptr));
    bool normalized = false;
    CFHandle<CFDictionaryRef> fixed(networkstate::repairedCheckpoint(networkstate::dictionary(value.get()), normalized));
    auto result = fixed.get();
    if (!result || !networkstate::valid(result, error)) { if (error.empty()) error = "corrupt network identity; recovery has been deferred"; return nullptr; }
    if (repaired) *repaired = normalized;
    CFRetain(result); return result;
}
bool NetworkServiceJournal::save(CFDictionaryRef value, std::string& error) const {
    if (!networkstate::valid(value, error)) return false;
    bool repaired = false;
    CFHandle<CFDictionaryRef> old(copy(error, &repaired));
    if (!error.empty()) return false;
    if (old && !repaired && CFEqual(old.get(), value)) return true;
    CFHandle<CFDataRef> data(CFPropertyListCreateData(nullptr, value, kCFPropertyListBinaryFormat_v1_0, 0, nullptr));
    if (!data || CFDataGetLength(data.get()) > static_cast<CFIndex>(kMaximumJournal)) { error = "network identity is too large"; return false; }
    Descriptor directory{openDirectory(true, error)};
    if (directory.value < 0) return false;
    const auto temporary = std::string(".network-service.plist.tmp.") + std::to_string(getpid()) + "." + std::to_string(arc4random());
    Descriptor file{openat(directory.value, temporary.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600)};
    if (file.value < 0) { error = "cannot create network identity checkpoint"; return false; }
    bool ok = true;
    auto bytes = CFDataGetBytePtr(data.get());
    size_t offset = 0, size = static_cast<size_t>(CFDataGetLength(data.get()));
    while (offset < size) {
        auto count = write(file.value, bytes + offset, size - offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) { ok = false; break; }
        offset += static_cast<size_t>(count);
    }
    ok = ok && fsync(file.value) == 0 && renameat(directory.value, temporary.c_str(), directory.value, kJournalFile) == 0;
    if (ok) (void)fsync(directory.value);
    else { error = "cannot commit durable network identity checkpoint"; (void)unlinkat(directory.value, temporary.c_str(), 0); }
    return ok;
}
bool NetworkServiceJournal::clear(std::string& error) const {
    error.clear();
    Descriptor directory{openDirectory(false, error)};
    if (directory.value < 0) return error.empty();
    Descriptor file{openat(directory.value, kJournalFile, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)};
    if (file.value < 0) { if (errno == ENOENT) return true; error = "cannot inspect owned network identity for cleanup"; return false; }
    if (!regularPrivate(file.value, owner_, error)) return false;
    if (unlinkat(directory.value, kJournalFile, 0) != 0) { error = "cannot remove owned network identity"; return false; }
    (void)fsync(directory.value);
    return true;
}
}
