// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <cstddef>
#include <string>
#include <vector>

namespace horndis {
enum class HomebrewOperation { unknown, replace, remove };
struct ProcessCommand {
    std::string executable;
    std::vector<std::string> arguments;
};
bool decodeProcessArguments(const char* data, size_t size, std::vector<std::string>& arguments);
HomebrewOperation classifyHomebrewCommand(const ProcessCommand& command, bool& isHomebrew);
HomebrewOperation currentHomebrewOperation();
}
