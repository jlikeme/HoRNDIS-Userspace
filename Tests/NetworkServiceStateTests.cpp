// SPDX-License-Identifier: GPL-3.0-or-later
#include "NetworkServiceState.hpp"
#include <algorithm>
#include <cassert>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <random>
#include <sys/stat.h>
#include <unistd.h>

using namespace horndis;
using namespace horndis::networkstate;
static const std::string oldID = "11111111-1111-4111-8111-111111111111";
static const std::string newID = "22222222-2222-4222-8222-222222222222";
static const std::string firstID = "33333333-3333-4333-8333-333333333333";
static const std::string lastID = "44444444-4444-4444-8444-444444444444";
static const std::string setID = "55555555-5555-4555-8555-555555555555";

static void string(CFMutableDictionaryRef target, CFStringRef key, const std::string& value) {
    CFHandle<CFStringRef> text(CFStringCreateWithCString(nullptr, value.c_str(), kCFStringEncodingUTF8));
    CFDictionarySetValue(target, key, text.get());
}
static CFMutableDictionaryRef newDictionary() { return CFDictionaryCreateMutable(nullptr, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks); }
static CFDictionaryRef configuration(const std::string& device, const std::string& name) {
    CFHandle<CFMutableDictionaryRef> result(newDictionary()), interface(newDictionary()), ipv4(newDictionary()), dns(newDictionary());
    string(interface.get(), CFSTR("DeviceName"), device); string(interface.get(), CFSTR("Hardware"), "Ethernet");
    string(interface.get(), CFSTR("Type"), "Ethernet"); string(interface.get(), CFSTR("UserDefinedName"), device);
    string(ipv4.get(), CFSTR("ConfigMethod"), "DHCP"); string(ipv4.get(), CFSTR("DHCPClientID"), "keep-my-client-setting");
    CFHandle<CFArrayRef> servers(copyStrings({"192.0.2.53"})); CFDictionarySetValue(dns.get(), CFSTR("ServerAddresses"), servers.get());
    string(result.get(), CFSTR("UserDefinedName"), name); CFDictionarySetValue(result.get(), CFSTR("Interface"), interface.get());
    CFDictionarySetValue(result.get(), CFSTR("IPv4"), ipv4.get()); CFDictionarySetValue(result.get(), CFSTR("DNS"), dns.get());
    return result.release();
}
struct Fixture {
    std::string directory;
    CFHandle<SCPreferencesRef> prefs;
    Fixture() {
        char pattern[] = "/private/tmp/horndis-identity-tests.XXXXXX";
        char* created = mkdtemp(pattern); assert(created); directory = created;
        const auto file = directory + "/isolated.plist";
        CFHandle<CFStringRef> path(CFStringCreateWithCString(nullptr, file.c_str(), kCFStringEncodingUTF8));
        prefs = CFHandle<SCPreferencesRef>(SCPreferencesCreate(nullptr, CFSTR("HoRNDIS isolated identity test"), path.get())); assert(prefs);
        CFHandle<CFStringRef> current(CFStringCreateWithCString(nullptr, ("/Sets/" + setID).c_str(), kCFStringEncodingUTF8));
        assert(SCPreferencesSetValue(prefs.get(), CFSTR("CurrentSet"), current.get()));
        CFHandle<CFMutableDictionaryRef> location(newDictionary()); string(location.get(), CFSTR("UserDefinedName"), "Test location");
        assert(setPath(prefs.get(), "/Sets/" + setID, location.get()));
        for (const auto& id : {firstID, oldID, lastID}) {
            CFHandle<CFDictionaryRef> config(configuration(id == oldID ? "bridge1" : "en0", id == oldID ? "My phone name" : "Other service"));
            assert(setPath(prefs.get(), "/NetworkServices/" + id, config.get()));
            CFHandle<CFStringRef> link(CFStringCreateWithCString(nullptr, ("/Sets/" + setID + "/Network/Service/" + id).c_str(), kCFStringEncodingUTF8));
            CFHandle<CFStringRef> target(CFStringCreateWithCString(nullptr, ("/NetworkServices/" + id).c_str(), kCFStringEncodingUTF8));
            assert(SCPreferencesPathSetLink(prefs.get(), link.get(), target.get()));
        }
        setOrder({firstID, oldID, lastID});
        CFHandle<CFMutableDictionaryRef> bridge(newDictionary()), options(newDictionary());
        string(options.get(), CFSTR("HoRNDISOwner"), kNetworkServiceOwner); string(options.get(), CFSTR("HoRNDISServiceID"), oldID);
        CFHandle<CFArrayRef> members(copyStrings({})); CFDictionarySetValue(bridge.get(), CFSTR("Interfaces"), members.get());
        CFDictionarySetValue(bridge.get(), CFSTR("Options"), options.get()); assert(setPath(prefs.get(), "/VirtualNetworkInterfaces/Bridge/bridge1", bridge.get()));
    }
    ~Fixture() { std::filesystem::remove_all(directory); }
    void setOrder(const std::vector<std::string>& values) {
        CFHandle<CFArrayRef> array(copyStrings(values)); CFHandle<CFMutableDictionaryRef> ipv4(newDictionary());
        CFDictionarySetValue(ipv4.get(), CFSTR("ServiceOrder"), array.get()); assert(setPath(prefs.get(), "/Sets/" + setID + "/Network/Global/IPv4", ipv4.get()));
    }
    std::vector<std::string> getOrder() {
        return strings(array(field(dictionary(pathValue(prefs.get(), "/Sets/" + setID + "/Network/Global/IPv4")), CFSTR("ServiceOrder"))));
    }
    CFDictionaryRef snapshot() {
        std::string error; auto value = capture(prefs.get(), "bridge1", oldID, false, error, "feth99");
        if (!value) std::cerr << error << '\n'; assert(value); return value;
    }
};

static void placementTests() {
    auto check = [](std::vector<std::string> saved, std::vector<std::string> current, std::vector<std::string> expected) {
        assert(placeOwnedService(saved, "old", "new", current).order == expected);
    };
    check({"a","b","old","c","d"}, {"a","b","c","d"}, {"a","b","new","c","d"});
    check({"a","b","old","c","d"}, {"a","x","c","d"}, {"a","new","x","c","d"});
    check({"a","b","old","c","d"}, {"x","c","d"}, {"x","new","c","d"});
    check({"a","b","old","c","d"}, {"a","b","x"}, {"a","b","new","x"});
    check({"a","old","b"}, {"x","y"}, {"x","y","new"});
    check({"a","b","old","c"}, {"c","b","a"}, {"c","b","new","a"});
    check({"a","old","b"}, {"old","a","b"}, {"new","a","b"});
    check({"a","old","b"}, {"a","new","old","b"}, {"a","new","b"});
    assert(placeOwnedService({"a","old","b"}, "old", "old", {"b","old","a"}).order == std::vector<std::string>({"b","old","a"}));
    std::mt19937 random(8713);
    for (int trial = 0; trial < 1000; ++trial) {
        std::vector<std::string> current{"a","b","c","d","x","y","old","new"}; std::shuffle(current.begin(), current.end(), random);
        current.resize(random() % (current.size() + 1)); auto before = current;
        before.erase(std::remove_if(before.begin(), before.end(), [](const auto& id) { return id == "old" || id == "new"; }), before.end());
        auto result = placeOwnedService({"a","b","old","c","d"}, "old", "new", current).order;
        assert(std::count(result.begin(), result.end(), "new") == 1);
        result.erase(std::remove(result.begin(), result.end(), "new"), result.end()); assert(result == before);
    }
    std::cout << "PASS: position anchors, deletions, new neighbors, crossed anchors, latest user order, and 1000 other-order invariants\n";
}
static void metadataTests() {
    Fixture f; CFHandle<CFDictionaryRef> state(f.snapshot());
    CFHandle<CFDictionaryRef> before(CFDictionaryCreateCopy(nullptr, dictionary(pathValue(f.prefs.get(), "/NetworkServices/" + firstID))));
    assert(SCPreferencesRemoveValue(f.prefs.get(), CFSTR("VirtualNetworkInterfaces")));
    assert(removePath(f.prefs.get(), "/NetworkServices/" + oldID));
    bool changed = false; std::string error;
    assert(restoreMetadata(f.prefs.get(), state.get(), false, changed, error) && changed);
    assert(CFEqual(pathValue(f.prefs.get(), "/NetworkServices/" + oldID), field(state.get(), CFSTR("ServiceConfiguration"))));
    assert(CFEqual(pathValue(f.prefs.get(), "/NetworkServices/" + firstID), before.get()));
    CFHandle<CFStringRef> own(CFStringCreateWithCString(nullptr, oldID.c_str(), kCFStringEncodingUTF8));
    CFHandle<SCNetworkServiceRef> service(SCNetworkServiceCopy(f.prefs.get(), own.get()));
    if (!service) std::cerr << "Isolated service copy: " << SCErrorString(SCError()) << '\n';
    assert(service && text(SCNetworkServiceGetServiceID(service.get())) == oldID);
    std::cout << "PASS: simulated system migration restores the original UUID, user settings and bridge metadata\n";

    Fixture conflict; CFHandle<CFDictionaryRef> saved(conflict.snapshot());
    CFHandle<CFDictionaryRef> foreign(configuration("en0", "Unrelated service"));
    assert(setPath(conflict.prefs.get(), "/NetworkServices/" + oldID, foreign.get()));
    changed = false; assert(!restoreMetadata(conflict.prefs.get(), saved.get(), false, changed, error));
    assert(!changed && CFEqual(pathValue(conflict.prefs.get(), "/NetworkServices/" + oldID), foreign.get()));
    Fixture occupied; CFHandle<CFDictionaryRef> occupiedState(occupied.snapshot());
    assert(SCPreferencesRemoveValue(occupied.prefs.get(), CFSTR("VirtualNetworkInterfaces")));
    changed = false; assert(!restoreMetadata(occupied.prefs.get(), occupiedState.get(), true, changed, error) && !changed);
    assert(!pathValue(occupied.prefs.get(), "/VirtualNetworkInterfaces/Bridge/bridge1"));
    std::cout << "PASS: reassigned UUIDs and unowned runtime bridge names are left unchanged\n";

    // A power loss after writing a replacement checkpoint but before committing
    // preferences must still prefer the original live UUID.
    CFHandle<CFMutableDictionaryRef> pending(CFDictionaryCreateMutableCopy(nullptr, 0, state.get()));
    CFHandle<CFStringRef> next(CFStringCreateWithCString(nullptr, newID.c_str(), kCFStringEncodingUTF8));
    CFDictionarySetValue(pending.get(), CFSTR("ServiceID"), next.get());
    CFHandle<CFMutableDictionaryRef> bridge(CFDictionaryCreateMutableCopy(nullptr, 0, dictionary(field(state.get(), CFSTR("BridgeConfiguration")))));
    CFHandle<CFMutableDictionaryRef> options(CFDictionaryCreateMutableCopy(nullptr, 0, dictionary(field(bridge.get(), CFSTR("Options")))));
    CFDictionarySetValue(options.get(), CFSTR("HoRNDISServiceID"), next.get());
    CFDictionarySetValue(bridge.get(), CFSTR("Options"), options.get());
    CFDictionarySetValue(pending.get(), CFSTR("BridgeConfiguration"), bridge.get());
    CFDictionarySetValue(pending.get(), CFSTR("NeedsApply"), kCFBooleanTrue);
    CFDictionarySetValue(pending.get(), CFSTR("Previous"), state.get());
    assert(valid(pending.get(), error));
    assert(preferredHistory(f.prefs.get(), pending.get()) == state.get());
    assert(removePath(f.prefs.get(), "/NetworkServices/" + oldID));
    CFHandle<CFDictionaryRef> nextConfig(configuration("bridge1", "Replacement"));
    assert(setPath(f.prefs.get(), "/NetworkServices/" + newID, nextConfig.get()));
    assert(preferredHistory(f.prefs.get(), pending.get()) == pending.get());
    std::cout << "PASS: interrupted replacement checkpoints prefer the original committed identity\n";
}
static void locationTests() {
    Fixture f; CFHandle<CFDictionaryRef> saved(f.snapshot());
    // The user moved the service after the checkpoint. The live slot wins.
    f.setOrder({oldID, lastID, firstID}); CFHandle<CFDictionaryRef> before(copySets(f.prefs.get()));
    CFHandle<CFDictionaryRef> replacement(configuration("bridge1", "Replacement phone"));
    assert(setPath(f.prefs.get(), "/NetworkServices/" + newID, replacement.get()));
    bool changed = false; std::string error, report;
    assert(removeServiceMetadata(f.prefs.get(), "bridge1", oldID, changed, error));
    CFHandle<CFStringRef> sid(CFStringCreateWithCString(nullptr, newID.c_str(), kCFStringEncodingUTF8));
    CFHandle<SCNetworkServiceRef> service(SCNetworkServiceCopy(f.prefs.get(), sid.get())); assert(service);
    if (!placeInSets(f.prefs.get(), before.get(), saved.get(), oldID, service.get(), true, changed, report, error)) std::cerr << error << ": " << SCErrorString(SCError()) << '\n';
    assert(error.empty()); assert(f.getOrder() == std::vector<std::string>({newID,lastID,firstID}));
    assert(!pathValue(f.prefs.get(), "/NetworkServices/" + oldID));
    std::cout << "PASS: a rebuilt UUID replaces the latest live slot without rearranging other services\n";

    Fixture anchor; CFHandle<CFDictionaryRef> history(anchor.snapshot());
    assert(removeServiceMetadata(anchor.prefs.get(), "bridge1", oldID, changed, error));
    CFHandle<CFDictionaryRef> surviving(copySets(anchor.prefs.get()));
    assert(setPath(anchor.prefs.get(), "/NetworkServices/" + newID, replacement.get()));
    CFHandle<SCNetworkServiceRef> rebuilt(SCNetworkServiceCopy(anchor.prefs.get(), sid.get())); assert(rebuilt);
    error.clear(); assert(placeInSets(anchor.prefs.get(), surviving.get(), history.get(), oldID, rebuilt.get(), true, changed, report, error));
    assert(anchor.getOrder() == std::vector<std::string>({firstID,newID,lastID}));
    assert(CFEqual(pathValue(anchor.prefs.get(), "/NetworkServices/" + newID), replacement.get()));
    std::cout << "PASS: a missing live slot is recovered from persisted UUID neighbors\n";
}
static void multipleLocationTests() {
    Fixture f;
    const std::string second = "66666666-6666-4666-8666-666666666666";
    const std::string unrelated = "77777777-7777-4777-8777-777777777777";
    auto addLocation = [&](const std::string& id, bool phone, const std::vector<std::string>& order) {
        CFHandle<CFMutableDictionaryRef> value(newDictionary()); string(value.get(), CFSTR("UserDefinedName"), id);
        assert(setPath(f.prefs.get(), "/Sets/" + id, value.get()));
        for (const auto& service : {firstID, oldID, lastID}) {
            if (!phone && service == oldID) continue;
            CFHandle<CFStringRef> path(CFStringCreateWithCString(nullptr, ("/Sets/" + id + "/Network/Service/" + service).c_str(), kCFStringEncodingUTF8));
            CFHandle<CFStringRef> target(CFStringCreateWithCString(nullptr, ("/NetworkServices/" + service).c_str(), kCFStringEncodingUTF8));
            assert(SCPreferencesPathSetLink(f.prefs.get(), path.get(), target.get()));
        }
        CFHandle<CFMutableDictionaryRef> ipv4(newDictionary()); CFHandle<CFArrayRef> ids(copyStrings(order));
        CFDictionarySetValue(ipv4.get(), CFSTR("ServiceOrder"), ids.get());
        assert(setPath(f.prefs.get(), "/Sets/" + id + "/Network/Global/IPv4", ipv4.get()));
    };
    addLocation(second, true, {lastID,oldID,firstID});
    addLocation(unrelated, false, {lastID,firstID});
    CFHandle<CFDictionaryRef> saved(f.snapshot()), before(copySets(f.prefs.get()));
    CFHandle<CFDictionaryRef> untouched(static_cast<CFDictionaryRef>(CFPropertyListCreateDeepCopy(nullptr, pathValue(f.prefs.get(), "/Sets/" + unrelated), kCFPropertyListImmutable)));
    bool changed = false; std::string error, report;
    assert(removeServiceMetadata(f.prefs.get(), "bridge1", oldID, changed, error));
    CFHandle<CFDictionaryRef> config(configuration("bridge1", "My phone name"));
    assert(setPath(f.prefs.get(), "/NetworkServices/" + newID, config.get()));
    CFHandle<CFStringRef> id(CFStringCreateWithCString(nullptr, newID.c_str(), kCFStringEncodingUTF8));
    CFHandle<SCNetworkServiceRef> service(SCNetworkServiceCopy(f.prefs.get(), id.get())); assert(service);
    assert(placeInSets(f.prefs.get(), before.get(), saved.get(), oldID, service.get(), true, changed, report, error));
    assert(f.getOrder() == std::vector<std::string>({firstID,newID,lastID}));
    auto secondOrder = strings(array(field(dictionary(pathValue(f.prefs.get(), "/Sets/" + second + "/Network/Global/IPv4")), CFSTR("ServiceOrder"))));
    assert(secondOrder == std::vector<std::string>({lastID,newID,firstID}));
    assert(CFEqual(pathValue(f.prefs.get(), "/Sets/" + unrelated), untouched.get()));
    assert(CFEqual(pathValue(f.prefs.get(), "/NetworkServices/" + newID), config.get()));
    std::cout << "PASS: per-location positions restored and unrelated locations/configurations untouched\n";

    // A deliberate membership removal is authoritative on an ordinary restart,
    // even if it happened just after the last persistent checkpoint.
    Fixture detached; CFHandle<CFDictionaryRef> stale(detached.snapshot());
    assert(removePath(detached.prefs.get(), "/Sets/" + setID + "/Network/Service/" + oldID));
    detached.setOrder({lastID,firstID}); CFHandle<CFDictionaryRef> live(copySets(detached.prefs.get()));
    CFHandle<CFStringRef> own(CFStringCreateWithCString(nullptr, oldID.c_str(), kCFStringEncodingUTF8));
    CFHandle<SCNetworkServiceRef> existing(SCNetworkServiceCopy(detached.prefs.get(), own.get())); assert(existing);
    error.clear(); assert(placeInSets(detached.prefs.get(), live.get(), stale.get(), oldID, existing.get(), false, changed, report, error));
    assert(detached.getOrder() == std::vector<std::string>({lastID,firstID}));
    assert(!pathValue(detached.prefs.get(), "/Sets/" + setID + "/Network/Service/" + oldID));
    std::cout << "PASS: latest explicit membership removals survive ordinary restarts\n";
}
static void storageTests() {
    Fixture f; CFHandle<CFDictionaryRef> state(f.snapshot()); const auto directory = f.directory + "/state";
    NetworkServiceJournal journal(directory, getuid()); std::string error;
    assert(!journal.copy(error) && error.empty()); assert(journal.save(state.get(), error));
    CFHandle<CFDictionaryRef> read(journal.copy(error)); assert(read && CFEqual(read.get(), state.get()));
    const auto file = directory + "/network-service.plist"; struct stat before{}, after{};
    assert(stat(file.c_str(), &before) == 0 && (before.st_mode & 0777) == 0600);
    assert(journal.save(state.get(), error)); assert(stat(file.c_str(), &after) == 0);
    assert(before.st_ino == after.st_ino && before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec && before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec);
    std::ofstream(file) << "corrupt"; assert(!journal.copy(error) && !error.empty());
    assert(!journal.save(state.get(), error)); assert(journal.clear(error)); assert(journal.save(state.get(), error));
    const auto other = f.directory + "/keep.plist"; std::filesystem::rename(file, other); assert(symlink(other.c_str(), file.c_str()) == 0);
    assert(!journal.copy(error) && !error.empty()); assert(!journal.save(state.get(), error)); assert(!journal.clear(error));
    assert(std::filesystem::exists(other)); assert(unlink(file.c_str()) == 0);
    assert(journal.save(state.get(), error)); assert(journal.clear(error)); assert(!journal.copy(error) && error.empty());
    NetworkServiceJournal foreign(f.directory + "/foreign", getuid() + 1);
    assert(!foreign.save(state.get(), error)); assert(!std::filesystem::exists(f.directory + "/foreign"));
    std::cout << "PASS: durable private checkpoints, no-op saves, corrupt-state protection, symlink refusal and uninstall clearing\n";
}
static void freshServiceTests() {
    Fixture f;
    CFHandle<CFStringRef> old(CFStringCreateWithCString(nullptr, oldID.c_str(), kCFStringEncodingUTF8));
    CFHandle<SCNetworkServiceRef> prior(SCNetworkServiceCopy(f.prefs.get(), old.get())); assert(prior);
    auto interface = SCNetworkServiceGetInterface(prior.get()); assert(interface);
    CFRetain(interface); CFHandle<SCNetworkInterfaceRef> retained(interface);
    bool changed = false; std::string error, report;
    assert(removeServiceMetadata(f.prefs.get(), "bridge1", oldID, changed, error));
    CFHandle<CFDictionaryRef> before(copySets(f.prefs.get()));
    CFHandle<CFDictionaryRef> other(CFDictionaryCreateCopy(nullptr, serviceConfiguration(f.prefs.get(), firstID)));
    CFHandle<SCNetworkServiceRef> fresh(SCNetworkServiceCreate(f.prefs.get(), interface)); assert(fresh);
    assert(initializeFreshService(fresh.get(), error));
    const auto id = text(SCNetworkServiceGetServiceID(fresh.get()));
    assert(!serviceConfiguration(f.prefs.get(), ""));
    assert(!serviceConfiguration(f.prefs.get(), "../"));
    CFHandle<CFDictionaryRef> config(configurationForCreatedService(f.prefs.get(), "", id, nullptr, error)); assert(config);
    assert(text(field(config.get(), CFSTR("UserDefinedName"))) == "HoRNDIS USB");
    assert(setPath(f.prefs.get(), "/NetworkServices/" + id, config.get()));
    assert(placeInSets(f.prefs.get(), before.get(), nullptr, "", fresh.get(), false, changed, report, error));
    assert(f.getOrder() == std::vector<std::string>({firstID,lastID,id}));
    assert(text(SCNetworkServiceGetName(fresh.get())) == "HoRNDIS USB");
    assert(SCNetworkServiceGetEnabled(fresh.get()));
    CFHandle<SCNetworkProtocolRef> ipv4(SCNetworkServiceCopyProtocol(fresh.get(), kSCNetworkProtocolTypeIPv4));
    assert(ipv4 && SCNetworkProtocolGetEnabled(ipv4.get()));
    assert(text(field(SCNetworkProtocolGetConfiguration(ipv4.get()), kSCPropNetIPv4ConfigMethod)) == "DHCP");
    CFHandle<CFStringRef> foreign(CFStringCreateWithCString(nullptr, firstID.c_str(), kCFStringEncodingUTF8));
    assert(!field(serviceConfiguration(f.prefs.get(), id), foreign.get()));
    assert(CFEqual(other.get(), serviceConfiguration(f.prefs.get(), firstID)));
    std::cout << "PASS: native first creation has HoRNDIS USB name, enabled DHCP, last position and no nested service table\n";
}
static void malformedDefaultsTests() {
    Fixture f; std::string error;
    CFHandle<CFDictionaryRef> state(f.snapshot());
    CFHandle<CFDictionaryRef> other(CFDictionaryCreateCopy(nullptr, serviceConfiguration(f.prefs.get(), firstID)));
    CFHandle<CFMutableDictionaryRef> malformed(CFDictionaryCreateMutableCopy(nullptr, 0, dictionary(SCPreferencesGetValue(f.prefs.get(), CFSTR("NetworkServices")))));
    auto original = serviceConfiguration(f.prefs.get(), oldID);
    CFDictionarySetValue(malformed.get(), CFSTR("Interface"), field(original, CFSTR("Interface")));
    CFDictionarySetValue(malformed.get(), CFSTR("UserDefinedName"), field(dictionary(field(original, CFSTR("Interface"))), CFSTR("UserDefinedName")));
    CFHandle<CFMutableDictionaryRef> disabled(newDictionary());
    CFDictionarySetValue(disabled.get(), CFSTR("ConfigMethod"), CFSTR("DHCP"));
    CFDictionarySetValue(disabled.get(), CFSTR("__INACTIVE__"), kCFBooleanTrue);
    CFDictionarySetValue(malformed.get(), CFSTR("IPv4"), disabled.get());
    CFHandle<CFDictionaryRef> repaired(repairNestedServiceTable(malformed.get(), oldID, "bridge1")); assert(repaired);
    assert(text(field(repaired.get(), CFSTR("UserDefinedName"))) == "HoRNDIS USB");
    assert(!field(dictionary(field(repaired.get(), CFSTR("IPv4"))), CFSTR("__INACTIVE__")));
    CFHandle<CFStringRef> nested(CFStringCreateWithCString(nullptr, oldID.c_str(), kCFStringEncodingUTF8));
    assert(!field(repaired.get(), nested.get()));
    assert(setPath(f.prefs.get(), "/NetworkServices/" + oldID, repaired.get()));
    assert(f.getOrder() == std::vector<std::string>({firstID,oldID,lastID}));
    assert(CFEqual(other.get(), serviceConfiguration(f.prefs.get(), firstID)));
    assert(!repairNestedServiceTable(original, oldID, "bridge1"));

    // Old checkpoints must be rewritten on disk after normalization, even when
    // their normalized in-memory value already equals the new checkpoint.
    CFHandle<CFMutableDictionaryRef> legacy(CFDictionaryCreateMutableCopy(nullptr, 0, state.get()));
    CFDictionarySetValue(legacy.get(), CFSTR("ServiceConfiguration"), malformed.get());
    assert(!valid(legacy.get(), error));
    NetworkServiceJournal journal(f.directory + "/legacy", getuid()); assert(journal.save(state.get(), error));
    CFHandle<CFDataRef> data(CFPropertyListCreateData(nullptr, legacy.get(), kCFPropertyListBinaryFormat_v1_0, 0, nullptr));
    const auto path = f.directory + "/legacy/network-service.plist";
    { std::ofstream output(path, std::ios::binary); output.write(reinterpret_cast<const char*>(CFDataGetBytePtr(data.get())), CFDataGetLength(data.get())); }
    bool normalized = false; CFHandle<CFDictionaryRef> loaded(journal.copy(error, &normalized)); assert(loaded && normalized);
    assert(journal.save(loaded.get(), error)); normalized = true;
    CFHandle<CFDictionaryRef> reread(journal.copy(error, &normalized)); assert(reread && !normalized);
    std::cout << "PASS: affected records and checkpoints are repaired in place without changing UUIDs, order or other services\n";
}
int main() { placementTests(); metadataTests(); locationTests(); multipleLocationTests(); storageTests(); freshServiceTests(); malformedDefaultsTests(); }
