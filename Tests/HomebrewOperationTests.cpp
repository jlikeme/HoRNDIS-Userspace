// SPDX-License-Identifier: GPL-3.0-or-later
#include "HomebrewOperation.hpp"
#include <cassert>
#include <cstring>
#include <iostream>

int main() {
    using namespace horndis;
    const std::string ruby = "/opt/homebrew/Library/Homebrew/vendor/portable-ruby/bin/ruby";
    const std::string brew = "/opt/homebrew/Library/Homebrew/brew.rb";
    bool found = false;
    for (const auto& action : {"reinstall", "upgrade", "install", "bundle"}) {
        assert(classifyHomebrewCommand({ruby, {"ruby", "-W0", brew, "--verbose", action, "--cask", "horndis"}}, found) == HomebrewOperation::replace);
        assert(found);
    }
    for (const auto& action : {"uninstall", "remove", "rm"}) {
        assert(classifyHomebrewCommand({ruby, {"ruby", brew, action, "--cask", "--zap", "horndis"}}, found) == HomebrewOperation::remove);
        assert(found);
    }
    assert(classifyHomebrewCommand({"/bin/bash", {"bash", "/usr/local/bin/brew", "upgrade", "horndis"}}, found) == HomebrewOperation::replace && found);
    assert(classifyHomebrewCommand({ruby, {"ruby", brew, "unknown", "uninstall"}}, found) == HomebrewOperation::unknown && found);
    assert(classifyHomebrewCommand({ruby, {"ruby", brew, "reinstall", "uninstall"}}, found) == HomebrewOperation::replace && found);
    assert(classifyHomebrewCommand({"/bin/python3", {"python3", brew, "uninstall"}}, found) == HomebrewOperation::unknown && !found);
    assert(classifyHomebrewCommand({ruby, {"ruby", "relative/Library/Homebrew/brew.rb", "uninstall"}}, found) == HomebrewOperation::unknown && !found);
    assert(classifyHomebrewCommand({ruby, {"ruby", "/tmp/other.rb", brew, "uninstall"}}, found) == HomebrewOperation::unknown && !found);
    assert(classifyHomebrewCommand({ruby, {"ruby", "-I", "/tmp/libs", brew, "uninstall"}}, found) == HomebrewOperation::remove && found);

    std::vector<char> buffer(sizeof(int));
    int count = 4;
    std::memcpy(buffer.data(), &count, sizeof(count));
    auto append = [&](const std::string& text) { buffer.insert(buffer.end(), text.begin(), text.end()); buffer.push_back(0); };
    append(ruby); buffer.push_back(0); buffer.push_back(0);
    for (const auto& argument : {"ruby", brew.c_str(), "reinstall", "--cask"}) append(argument);
    append("PRIVATE_ENVIRONMENT=not-an-argument");
    std::vector<std::string> arguments;
    assert(decodeProcessArguments(buffer.data(), buffer.size(), arguments));
    assert(arguments.size() == 4 && arguments[2] == "reinstall");
    assert(!decodeProcessArguments(buffer.data(), sizeof(int), arguments));
    assert(!decodeProcessArguments(buffer.data(), sizeof(int) + ruby.size(), arguments));
    count = 9000; std::memcpy(buffer.data(), &count, sizeof(count));
    assert(!decodeProcessArguments(buffer.data(), buffer.size(), arguments));
    std::cout << "Homebrew operation classification and bounded kernel argv decoding passed\n";
}
