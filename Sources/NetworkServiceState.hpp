// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <SystemConfiguration/SystemConfiguration.h>
#include <sys/types.h>
#include <string>
#include <vector>

namespace horndis {
template<class T> class CFHandle {
public:
    explicit CFHandle(T value = nullptr) : value_(value) {}
    ~CFHandle() { if (value_) CFRelease(value_); }
    CFHandle(const CFHandle&) = delete;
    CFHandle& operator=(const CFHandle&) = delete;
    CFHandle(CFHandle&& other) noexcept : value_(other.release()) {}
    CFHandle& operator=(CFHandle&& other) noexcept {
        if (this != &other) { if (value_) CFRelease(value_); value_ = other.release(); }
        return *this;
    }
    T get() const { return value_; }
    T release() { T result = value_; value_ = nullptr; return result; }
    explicit operator bool() const { return value_ != nullptr; }
private:
    T value_;
};

inline constexpr const char* kNetworkServiceOwner = "io.github.noahhhi.horndis.network-v1";
struct RelativeServicePlacement {
    std::vector<std::string> order;
    std::string source;
};
RelativeServicePlacement placeOwnedService(const std::vector<std::string>& saved,
    const std::string& oldID, const std::string& newID, const std::vector<std::string>& current);

namespace networkstate {
std::string text(CFTypeRef value);
CFDictionaryRef dictionary(CFTypeRef value);
CFArrayRef array(CFTypeRef value);
CFTypeRef field(CFDictionaryRef value, CFStringRef key);
std::vector<std::string> strings(CFArrayRef value);
CFArrayRef copyStrings(const std::vector<std::string>& values);
CFTypeRef pathValue(SCPreferencesRef prefs, const std::string& path);
bool setPath(SCPreferencesRef prefs, const std::string& path, CFDictionaryRef value);
bool removePath(SCPreferencesRef prefs, const std::string& path);
bool valid(CFDictionaryRef state, std::string& error);
bool validServiceID(const std::string& value);
CFDictionaryRef serviceConfiguration(SCPreferencesRef prefs, const std::string& serviceID);
bool initializeFreshService(SCNetworkServiceRef service, std::string& error);
CFDictionaryRef configurationForCreatedService(SCPreferencesRef prefs, const std::string& oldID,
    const std::string& newID, CFDictionaryRef history, std::string& error);
CFDictionaryRef repairNestedServiceTable(CFDictionaryRef configuration,
    const std::string& serviceID, const std::string& bridge);
CFDictionaryRef preferredHistory(SCPreferencesRef prefs, CFDictionaryRef state);
CFDictionaryRef capture(SCPreferencesRef prefs, const std::string& bridge,
    const std::string& serviceID, bool needsApply, std::string& error, const std::string& member = "");
bool restoreMetadata(SCPreferencesRef prefs, CFDictionaryRef state,
    bool runtimeBridgeExists, bool& changed, std::string& error);
CFDictionaryRef copySets(SCPreferencesRef prefs);
bool placeInSets(SCPreferencesRef prefs, CFDictionaryRef beforeSets, CFDictionaryRef history,
    const std::string& oldID, SCNetworkServiceRef service, bool recovering,
    bool& changed, std::string& report, std::string& error);
bool removeServiceMetadata(SCPreferencesRef prefs, const std::string& bridge,
    const std::string& serviceID, bool& changed, std::string& error);
}

// Production callers always use the fixed root-owned directory and UID 0.
// Explicit paths/owners are for isolated, unprivileged storage tests only.
class NetworkServiceJournal {
public:
    explicit NetworkServiceJournal(std::string directory = "/Library/Application Support/HoRNDIS",
                                   uid_t owner = 0);
    CFDictionaryRef copy(std::string& error, bool* repaired = nullptr) const;
    bool save(CFDictionaryRef value, std::string& error) const;
    bool clear(std::string& error) const;
private:
    int openDirectory(bool create, std::string& error) const;
    std::string directory_;
    uid_t owner_;
};
}
