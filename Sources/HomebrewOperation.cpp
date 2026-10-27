// SPDX-License-Identifier: GPL-3.0-or-later
#include "HomebrewOperation.hpp"
#include <libproc.h>
#include <sys/sysctl.h>
#include <unistd.h>
#include <cstring>
#include <set>

namespace horndis {
bool decodeProcessArguments(const char* data, size_t size, std::vector<std::string>& arguments) {
    arguments.clear();
    if (!data || size <= sizeof(int)) return false;
    int count = 0;
    std::memcpy(&count, data, sizeof(count));
    if (count <= 0 || count > 8192) return false;
    size_t offset = sizeof(count);
    auto stringAt = [&](std::string& value) {
        if (offset >= size) return false;
        auto end = static_cast<const char*>(std::memchr(data + offset, 0, size - offset));
        if (!end) return false;
        value.assign(data + offset, end);
        offset = static_cast<size_t>(end - data) + 1;
        return true;
    };
    std::string executable;
    if (!stringAt(executable)) return false;
    while (offset < size && data[offset] == 0) ++offset;
    for (int index = 0; index < count; ++index) {
        std::string argument;
        if (!stringAt(argument)) { arguments.clear(); return false; }
        arguments.push_back(argument);
    }
    return true;
}

HomebrewOperation classifyHomebrewCommand(const ProcessCommand& command, bool& isHomebrew) {
    isHomebrew = false;
    const auto slash = command.executable.find_last_of('/');
    const auto executable = command.executable.substr(slash == std::string::npos ? 0 : slash + 1);
    const bool ruby = executable == "ruby";
    const bool shell = executable == "bash" || executable == "zsh" || executable == "sh";
    if (!ruby && !shell) return HomebrewOperation::unknown;
    for (size_t index = 1; index < command.arguments.size(); ++index) {
        const auto& script = command.arguments[index];
        if (script.empty()) continue;
        if (script.front() == '-') {
            if (ruby && (script == "-I" || script == "-r" || script == "-C" || script == "-e")) ++index;
            continue;
        }
        // Only the interpreter's script can identify Homebrew. A different
        // script mentioning brew.rb in its own arguments is not a brew command.
        if (script.front() != '/' ||
            !(ruby ? script.ends_with("/Library/Homebrew/brew.rb") : script.ends_with("/bin/brew"))) return HomebrewOperation::unknown;
        isHomebrew = true;
        // Parse actual kernel argv entries, not a ps command string or substring.
        // Ruby's modification of ARGV after startup does not change this argv.
        for (++index; index < command.arguments.size(); ++index) {
            const auto& action = command.arguments[index];
            if (action.empty() || action.front() == '-') continue;
            if (action == "uninstall" || action == "remove" || action == "rm") return HomebrewOperation::remove;
            if (action == "reinstall" || action == "upgrade" || action == "install" || action == "bundle") return HomebrewOperation::replace;
            return HomebrewOperation::unknown;
        }
        return HomebrewOperation::unknown;
    }
    return HomebrewOperation::unknown;
}

HomebrewOperation currentHomebrewOperation() {
    pid_t process = getppid();
    std::set<pid_t> visited;
    for (int depth = 0; depth < 64 && process > 1 && visited.insert(process).second; ++depth) {
        proc_bsdinfo information{};
        if (proc_pidinfo(process, PROC_PIDTBSDINFO, 0, &information, sizeof(information)) != sizeof(information)) break;
        char executable[PROC_PIDPATHINFO_MAXSIZE]{};
        ProcessCommand command;
        if (proc_pidpath(process, executable, sizeof(executable)) > 0) {
            command.executable = executable;
            int query[] = {CTL_KERN, KERN_PROCARGS2, process};
            size_t size = 1024 * 1024;
            std::vector<char> data(size);
            if (sysctl(query, 3, data.data(), &size, nullptr, 0) == 0 &&
                decodeProcessArguments(data.data(), size, command.arguments)) {
                bool isHomebrew = false;
                const auto result = classifyHomebrewCommand(command, isHomebrew);
                // The nearest Homebrew invocation owns the operation. Unknown
                // operations must never inherit a destructive outer command.
                if (isHomebrew) return result;
            }
        }
        process = static_cast<pid_t>(information.pbi_ppid);
    }
    return HomebrewOperation::unknown;
}
}
