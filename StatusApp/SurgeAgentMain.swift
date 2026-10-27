// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin

@main
enum SurgeAgentEntryPoint {
    static func main() {
        AgentRuntime.configureSignals()
        do {
            switch CommandLine.arguments.dropFirst().first ?? "run" {
            case "run": try SurgeAgentWorker.run()
            case "--inspect": try SurgeAgentWorker.inspect()
            case "--inspect-adb": try ADBAutoService.inspect()
            case "--help": print("Usage: horndis-surge-agent run | --inspect | --inspect-adb (read-only)")
            default: throw SurgeIntegrationError.configuration("Unknown Surge agent command.")
            }
        } catch {
            if CommandLine.arguments.dropFirst().first ?? "run" == "run" {
                let storage = SurgeStorage.standard
                try? storage.save(SurgeLinkStatus(state: "error", detail: error.localizedDescription), to: storage.statusURL)
                AgentRuntime.log("fatal startup error: \(error.localizedDescription)", storage: storage)
            }
            AgentRuntime.writeStandardError(error.localizedDescription)
            exit(1)
        }
    }
}
