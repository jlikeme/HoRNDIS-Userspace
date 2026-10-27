// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin

private enum Failure: Error { case assertion(String) }
private func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw Failure.assertion(message) }
}

@main
private enum AgentRuntimeTests {
    static func main() throws {
        if let mode = CommandLine.arguments.dropFirst().first {
            child(mode)
            return
        }
        AgentRuntime.configureSignals()
        let tests: [(String, () throws -> Void)] = [
            ("default SIGPIPE terminates the reproducer", defaultSignal),
            ("agent policy turns broken-pipe signals into recoverable EPIPE", ignoredSignal),
            ("error reporting tolerates a disconnected stderr reader", closedErrorStream),
            ("DNS sockets suppress SIGPIPE independently of process policy", protectedDNSSocket),
            ("storage paths have explicit directory and file semantics", storagePaths),
            ("launch configuration has independent standard streams", launchConfiguration),
            ("private agent logging rotates and rejects symbolic links", rotatingLog),
        ]
        for (name, test) in tests { try test(); print("PASS: \(name)") }
        print("Agent runtime: \(tests.count) tests passed")
    }

    static func child(_ mode: String) {
        if mode == "dns-socket" {
            signal(SIGPIPE, SIG_DFL)
            let descriptor = SurgeDNSProbe.openSocket()
            guard descriptor >= 0 else { exit(20) }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = UInt16(9).bigEndian
            inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard connected == 0, shutdown(descriptor, SHUT_WR) == 0 else { exit(21) }
            var byte: UInt8 = 0
            let count = send(descriptor, &byte, 1, 0)
            exit(count == -1 && errno == EPIPE ? 0 : 22)
        }
        if mode == "unsafe" { signal(SIGPIPE, SIG_DFL) }
        else { AgentRuntime.configureSignals() }
        var descriptors: [Int32] = [-1, -1]
        guard pipe(&descriptors) == 0 else { exit(10) }
        close(descriptors[0])
        if mode == "stderr" {
            dup2(descriptors[1], STDERR_FILENO)
            if descriptors[1] != STDERR_FILENO { close(descriptors[1]) }
            AgentRuntime.writeStandardError("A recoverable startup error")
            exit(0)
        }
        var byte: UInt8 = 1
        let count = Darwin.write(descriptors[1], &byte, 1)
        exit(count == -1 && errno == EPIPE ? 0 : 11)
    }

    static func runChild(_ mode: String) throws -> SurgeCommandResult {
        try SurgeProcess.run(URL(fileURLWithPath: CommandLine.arguments[0], isDirectory: false), [mode])
    }
    static func defaultSignal() throws {
        let result = try runChild("unsafe")
        try check(result.signal == SIGPIPE, "Observe the same terminating signal as the field failure")
    }
    static func ignoredSignal() throws {
        let result = try runChild("safe")
        try check(result.status == 0 && result.signal == nil, "The process must survive the closed peer")
    }
    static func closedErrorStream() throws {
        let result = try runChild("stderr")
        try check(result.status == 0 && result.signal == nil, "Error reporting cannot kill the daemon")
    }
    static func protectedDNSSocket() throws {
        let result = try runChild("dns-socket")
        try check(result.status == 0 && result.signal == nil, "A closed UDP send must return EPIPE even with the default SIGPIPE disposition")
    }
    static func storagePaths() throws {
        let storage = SurgeStorage(directory: URL(fileURLWithPath: "/private/tmp/does-not-exist/HoRNDIS/Surge", isDirectory: true))
        try check(storage.directory.hasDirectoryPath, "Directory role is explicit")
        for url in [storage.settingsURL, storage.journalURL, storage.statusURL, storage.adbStatusURL, storage.policyJournalURL] {
            try check(!url.hasDirectoryPath && url.deletingLastPathComponent().path == storage.directory.path, "Known files do not need filesystem type inference")
        }
    }
    static func launchConfiguration() throws {
        let configuration = SurgeAgentManager.configuration(executable: URL(fileURLWithPath: "/Applications/HoRNDIS Status.app/Contents/Helpers/horndis-surge-agent", isDirectory: false))
        for key in ["StandardInPath", "StandardOutPath", "StandardErrorPath"] {
            try check(configuration[key] as? String == "/dev/null", "Do not inherit a launcher's pipe")
        }
        try check(configuration["KeepAlive"] as? Bool == true, "Retain automatic restart")
        try check(configuration["AssociatedBundleIdentifiers"] as? [String] == ["io.github.noahhhi.horndis.status"], "Attribute local network access to the app")
    }
    static func rotatingLog() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("horndis-log-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = SurgeStorage(directory: directory)
        let log = directory.appendingPathComponent("agent.log", isDirectory: false)
        let previous = directory.appendingPathComponent("agent.log.1", isDirectory: false)
        for index in 0..<650 { AgentRuntime.log("entry=\(index) " + String(repeating: "x", count: 1900), storage: storage) }
        for url in [log, previous] {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            try check((attributes[.size] as? NSNumber)?.intValue ?? Int.max <= AgentRuntime.maximumLogBytes, "Bound disk use")
            try check((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "Logs are user-private")
        }
        try FileManager.default.removeItem(at: log)
        let other = directory.appendingPathComponent("keep.txt", isDirectory: false)
        try Data("keep".utf8).write(to: other)
        try FileManager.default.createSymbolicLink(at: log, withDestinationURL: other)
        AgentRuntime.log("must not be written", storage: storage)
        try check(try String(contentsOf: other, encoding: .utf8) == "keep", "Do not follow a log symlink")
    }
}
