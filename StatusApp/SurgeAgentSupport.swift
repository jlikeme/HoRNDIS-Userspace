// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import AppKit
import Darwin

struct SurgeCommandResult {
    let status: Int32
    let output: String
    var signal: Int32? = nil
}

private final class SurgeCommandBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk.prefix(max(0, 256 * 1024 - data.count)))
    }
    var text: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

enum SurgeProcess {
    static func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval = 4,
                    environment: [String: String]? = nil) throws -> SurgeCommandResult {
        let process = Process()
        let pipe = Pipe()
        let finished = DispatchSemaphore(value: 0)
        let drained = DispatchSemaphore(value: 0)
        let buffer = SurgeCommandBuffer()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = pipe
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        try? pipe.fileHandleForWriting.close()
        DispatchQueue.global(qos: .utility).async {
            defer { try? pipe.fileHandleForReading.close(); drained.signal() }
            while let data = try? pipe.fileHandleForReading.read(upToCount: 8192), !data.isEmpty {
                buffer.append(data)
            }
        }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 0.3) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 1)
            }
            _ = drained.wait(timeout: .now() + 0.2)
            throw SurgeIntegrationError.command("\(executable.lastPathComponent) timed out; the operation will be checked and retried.")
        }
        _ = drained.wait(timeout: .now() + 1)
        return SurgeCommandResult(status: process.terminationStatus, output: buffer.text,
            signal: process.terminationReason == .uncaughtSignal ? process.terminationStatus : nil)
    }
}

final class SurgeCLI: SurgeControlling {
    private let executableOverride: URL?
    init(executable: URL? = nil) { executableOverride = executable }

    private func executable() throws -> URL {
        if let executableOverride { return executableOverride }
        let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.nssurge.surge-mac")
            ?? URL(fileURLWithPath: "/Applications/Surge.app", isDirectory: true)
        let executable = application.appendingPathComponent("Contents/Applications/surge-cli", isDirectory: false)
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw SurgeIntegrationError.configuration("Surge CLI was not found. Install Surge Mac 6.8 or later.")
        }
        return executable
    }

    @discardableResult
    private func command(_ arguments: [String]) throws -> String {
        let result = try SurgeProcess.run(executable(), arguments)
        if let signal = result.signal {
            throw SurgeIntegrationError.command("Surge command terminated by signal \(signal): \(arguments.joined(separator: " "))")
        }
        let lower = result.output.lowercased()
        if lower.contains("isn't running") || lower.contains("is not running") || lower.contains("not running on the local") {
            throw SurgeIntegrationError.unavailable
        }
        guard result.status == 0 else {
            throw SurgeIntegrationError.command("Surge \(arguments.joined(separator: " ")) failed: \(result.output.prefix(400))")
        }
        return result.output
    }

    func modules() throws -> SurgeModules {
        let output = try command(["--raw", "module", "list"])
        guard let value = try? JSONDecoder().decode(SurgeModules.self, from: Data(output.utf8)) else {
            throw SurgeIntegrationError.command("Surge returned an invalid module list. Surge Mac 6.8 or later is required.")
        }
        return value
    }
    func currentProfile() throws -> String {
        struct Profiles: Decodable { let current: String }
        let output = try command(["--raw", "profile", "list"])
        return try JSONDecoder().decode(Profiles.self, from: Data(output.utf8)).current
    }
    func checkProfile(_ path: String) throws { try command(["--check", path]) }
    func reload() throws { try command(["reload"]) }
    func setModuleEnabled(_ enabled: Bool) throws {
        try command(["module", enabled ? "enable" : "disable", SurgeConfiguration.moduleName])
    }
    func flushDNS() throws { try command(["flush", "dns"]) }
    func intelligenceGroup() throws -> SurgePolicyGroup {
        struct Response: Decodable { let group: SurgePolicyGroup }
        let output = try command(["--raw", "policy-group", "get", SurgePolicyCoordinator.group])
        return try JSONDecoder().decode(Response.self, from: Data(output.utf8)).group
    }
    func selectIntelligence(_ policy: String) throws {
        guard [SurgePolicyCoordinator.phone, SurgePolicyCoordinator.fallback].contains(policy) else {
            throw SurgeIntegrationError.configuration("Unsupported Intelligence selection.")
        }
        try command(["policy-group", "set", SurgePolicyCoordinator.group, policy])
    }
}

enum SurgeAgentManager {
    static let label = "io.github.noahhhi.horndis.surge"
    private static let installationLock = NSLock()
    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist", isDirectory: false)
    }
    static var defaultModulePath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        for directory in ["Library/Mobile Documents/iCloud~com~nssurge~inc/Documents",
                          "Library/Application Support/Surge/Profiles",
                          "Library/Application Support/com.nssurge.surge-mac/Profiles"] {
            let url = home.appendingPathComponent(directory, isDirectory: true).appendingPathComponent("SIM-DNS.sgmodule", isDirectory: false)
            if FileManager.default.fileExists(atPath: url.path) { return url.path }
        }
        return ""
    }

    static func configuration(executable: URL) -> [String: Any] {
        ["Label": label, "ProgramArguments": [executable.path, "run"],
         "RunAtLoad": true, "KeepAlive": true, "LimitLoadToSessionType": "Aqua",
         "AssociatedBundleIdentifiers": ["io.github.noahhhi.horndis.status"],
         "ThrottleInterval": 10, "ExitTimeOut": 20,
         "StandardInPath": "/dev/null", "StandardOutPath": "/dev/null", "StandardErrorPath": "/dev/null"]
    }

    static func ensureRunning(restart: Bool = false) throws {
        installationLock.lock()
        defer { installationLock.unlock() }
        let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/horndis-surge-agent", isDirectory: false)
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw SurgeIntegrationError.configuration("The bundled Surge integration agent is missing. Reinstall HoRNDIS.")
        }
        let data = try PropertyListSerialization.data(fromPropertyList: configuration(executable: executable), format: .xml, options: 0)
        let launchctl = URL(fileURLWithPath: "/bin/launchctl", isDirectory: false)
        let target = "gui/\(getuid())/\(label)"
        let changed = (try? Data(contentsOf: plistURL)) != data
        if changed || restart {
            _ = try SurgeProcess.run(launchctl, ["bootout", target])
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            while ProcessInfo.processInfo.systemUptime < deadline {
                if try SurgeProcess.run(launchctl, ["print", target]).status != 0 { break }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        if changed {
            try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: plistURL, options: .atomic)
        }
        let loaded = try SurgeProcess.run(launchctl, ["print", target]).status == 0
        if !loaded {
            var result = try SurgeProcess.run(launchctl, ["bootstrap", "gui/\(getuid())", plistURL.path])
            for _ in 0..<5 where result.status != 0 {
                // launchd can briefly reject bootstrap while the previous job is
                // being removed. Bound the retry rather than losing the service.
                Thread.sleep(forTimeInterval: 0.3)
                if try SurgeProcess.run(launchctl, ["print", target]).status == 0 {
                    result = SurgeCommandResult(status: 0, output: "")
                    break
                }
                result = try SurgeProcess.run(launchctl, ["bootstrap", "gui/\(getuid())", plistURL.path])
            }
            guard result.status == 0 else {
                throw SurgeIntegrationError.command("Cannot start the Surge integration agent: \(result.output.prefix(300))")
            }
        }
        let result = try SurgeProcess.run(launchctl, ["kickstart", target])
        guard result.status == 0 else {
            throw SurgeIntegrationError.command("Cannot start the Surge integration agent: \(result.output.prefix(300))")
        }
    }

    static func restoreIfNeeded(restart: Bool = false) throws {
        let settings = try SurgeStorage.standard.settings()
        let journal = try SurgeStorage.standard.journal()
        let policyJournal = try SurgeStorage.standard.policyJournal()
        if settings.enabled || settings.autoStartUSB || journal.ownsModule || journal.needsFlush || journal.needsReload || policyJournal.pending ||
            (settings.hasBeenEnabled && !settings.cleanupRevision.isEmpty && journal.cleanedRevision != settings.cleanupRevision) ||
            (restart && FileManager.default.fileExists(atPath: plistURL.path)) {
            try ensureRunning(restart: restart)
        }
    }

    // Leave the agent installed if Surge is unavailable: pending cleanup must survive.
    static func cleanupComplete(settings: SurgeSettings, journal: SurgeJournal, policy: SurgePolicyJournal) -> Bool {
        !journal.ownsModule && !journal.needsFlush && !journal.needsReload && !policy.pending &&
            (!settings.hasBeenEnabled || journal.cleanedRevision == settings.cleanupRevision)
    }

    static func uninstall() throws {
        let storage = SurgeStorage.standard
        var settings = try storage.settings()
        let journal = try storage.journal()
        let policyJournal = try storage.policyJournal()
        guard settings.hasBeenEnabled || settings.autoStartUSB || journal.ownsModule || policyJournal.pending || FileManager.default.fileExists(atPath: plistURL.path) else { return }
        settings.enabled = false
        settings.autoStartUSB = false
        settings.changed(requestCleanup: true)
        try storage.save(settings, to: storage.settingsURL)
        try ensureRunning()
        let deadline = ProcessInfo.processInfo.systemUptime + 12
        var cleaned = false
        while ProcessInfo.processInfo.systemUptime < deadline {
            let current = try storage.journal()
            let policy = try storage.policyJournal()
            if cleanupComplete(settings: settings, journal: current, policy: policy) {
                cleaned = true; break
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        guard cleaned else {
            throw SurgeIntegrationError.command("Surge integration cleanup (SIM DNS / Intelligence) is still pending. Keep HoRNDIS installed, open Surge and return to any pending profile, then retry uninstalling.")
        }
        let result = try SurgeProcess.run(URL(fileURLWithPath: "/bin/launchctl", isDirectory: false), ["bootout", "gui/\(getuid())/\(label)"])
        guard result.status == 0 else {
            throw SurgeIntegrationError.command("Cannot unload the Surge integration agent: \(result.output.prefix(300))")
        }
        if FileManager.default.fileExists(atPath: plistURL.path) { try FileManager.default.removeItem(at: plistURL) }
    }
}

private final class SurgeStopToken: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var stopped: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func stop() { lock.lock(); value = true; lock.unlock() }
}

enum SurgeAgentWorker {
    static func run(storage: SurgeStorage = .standard) throws {
        guard getuid() != 0 else { throw SurgeIntegrationError.configuration("Run Surge integration as the logged-in user, not root.") }
        try FileManager.default.createDirectory(at: storage.directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let lock = open(storage.directory.appendingPathComponent("agent.lock", isDirectory: false).path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw POSIXError(.EIO) }
        defer { close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { return }
        AgentRuntime.log("agent started", storage: storage)
        let stop = SurgeStopToken()
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        let signals = [SIGTERM, SIGINT].map { number -> DispatchSourceSignal in
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global(qos: .utility))
            source.setEventHandler { stop.stop() }
            source.resume()
            return source
        }
        defer { signals.forEach { $0.cancel() } }
        let adb = ADBAutoService(storage: storage, allowed: { !stop.stopped })
        adb.start()
        defer { adb.stop() }
        let network = try SurgeNetworkObserver()
        network.watch()
        var coordinator: SurgeLinkCoordinator?
        var previousSettings: SurgeSettings?
        var previousNetwork: SurgePhoneNetwork?
        var readyNetwork: SurgePhoneNetwork?
        var lastProbe: TimeInterval = 0
        var dnsProbeDetail = ""
        var dnsPermissionDenied = false
        var nextAttempt: TimeInterval = 0
        var lastPublished: TimeInterval = 0
        var failures = 0
        var report = SurgeLinkStatus(state: "off")
        var loggedState = ""
        var publicationError = ""
        while !stop.stopped {
            let now = ProcessInfo.processInfo.systemUptime
            var inputValid = false
            do {
                let settings = try storage.settings()
                let phone = settings.enabled ? try network.snapshot() : nil
                inputValid = true
                if settings != previousSettings || phone != previousNetwork {
                    if phone != previousNetwork { readyNetwork = nil }
                    nextAttempt = 0
                    failures = 0
                    previousSettings = settings
                    previousNetwork = phone
                }
                if now >= nextAttempt {
                    if coordinator == nil { coordinator = try SurgeLinkCoordinator(controller: SurgeCLI(), storage: storage) }
                    guard let coordinator else { throw SurgeIntegrationError.configuration("Cannot initialize Surge integration.") }
                    if let phone, settings.enabled, readyNetwork != phone || now - lastProbe > 60 {
                        if let last = coordinator.journal.lastNetwork, last != phone {
                            // An old phone session must not supply DNS while a new one is probed.
                            report = try coordinator.reconcile(settings: settings, network: phone, dnsReady: false, stillCurrent: { false })
                            try storage.save(report, to: storage.statusURL)
                        }
                        let probe = SurgeDNSProbe.check(phone)
                        readyNetwork = probe.ready ? phone : nil
                        dnsProbeDetail = probe.ready ? "" : probe.detail
                        dnsPermissionDenied = probe.localNetworkDenied
                        lastProbe = now
                    }
                    report = try coordinator.reconcile(settings: settings, network: phone,
                        dnsReady: phone != nil && readyNetwork == phone, stillCurrent: {
                            !stop.stopped && (try? storage.settings()) == settings && (try? network.snapshot()) == phone
                        })
                    if report.state == "waitingDNS" {
                        report.detail = dnsProbeDetail
                        if dnsPermissionDenied { report.state = "localNetworkDenied" }
                    }
                    failures = 0
                    nextAttempt = ProcessInfo.processInfo.systemUptime + 5
                    lastPublished = 0
                }
            } catch {
                failures += 1
                let intervals: [TimeInterval] = [2, 5, 10, 30]
                nextAttempt = ProcessInfo.processInfo.systemUptime + intervals[min(failures - 1, intervals.count - 1)]
                let waiting = (error as? SurgeIntegrationError).map {
                    if case .unavailable = $0 { return true }; return false
                } ?? false
                report = SurgeLinkStatus(state: waiting ? "waitingSurge" : "error",
                                         detail: error.localizedDescription, network: previousNetwork)
                lastPublished = 0
                // Corrupt preferences must not leave a previously managed module enabled.
                if !inputValid {
                    if coordinator == nil { coordinator = try? SurgeLinkCoordinator(controller: SurgeCLI(), storage: storage) }
                    var disabled = previousSettings ?? SurgeSettings()
                    disabled.enabled = false
                    _ = try? coordinator?.reconcile(settings: disabled, network: nil, dnsReady: false, stillCurrent: { false })
                }
            }
            if now - lastPublished >= 5 || lastPublished == 0 {
                report.updatedAt = Date().timeIntervalSince1970
                let network = report.network
                let state = "link state=\(report.state) interface=\(network?.interface ?? "-") address=\(network?.address ?? "-") dns=\(network?.dnsServers.joined(separator: ",") ?? "-") gateway=\(network?.gateway ?? "-") session=\(network?.session ?? "-") policy=\(report.policySelection ?? "-") \(report.detail)"
                if state != loggedState { AgentRuntime.log(state, storage: storage); loggedState = state }
                do {
                    try storage.save(report, to: storage.statusURL)
                    publicationError = ""
                } catch {
                    let message = "link status publication failed: \(error.localizedDescription)"
                    if message != publicationError { AgentRuntime.log(message, storage: storage); publicationError = message }
                }
                lastPublished = now
            }
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(1))
        }
        if let coordinator {
            var settings = (try? storage.settings()) ?? previousSettings ?? SurgeSettings()
            settings.enabled = false
            _ = try? coordinator.reconcile(settings: settings, network: nil, dnsReady: false, stillCurrent: { false })
        }
        AgentRuntime.log("agent stopped", storage: storage)
    }

    // Read-only acceptance probe: no settings, modules or profiles are modified.
    static func inspect() throws {
        let observer = try SurgeNetworkObserver()
        let phone = try observer.snapshot()
        let cli = SurgeCLI()
        let modules = try cli.modules()
        let profileName = try cli.currentProfile()
        var settings = try SurgeStorage.standard.settings()
        if settings.modulePath.isEmpty { settings.modulePath = SurgeAgentManager.defaultModulePath }
        var result: [String: Any] = ["active_profile": profileName,
            "module_enabled": modules.enabled.contains(SurgeConfiguration.moduleName),
            "dns_ready": phone.map(SurgeDNSProbe.ready) ?? false]
        if let group = try? cli.intelligenceGroup() {
            result["intelligence"] = ["selected": group.selected,
                "phone_available": group.contains(SurgePolicyCoordinator.phone),
                "fallback_available": group.contains(SurgePolicyCoordinator.fallback),
                "automatic_switching": settings.switchIntelligence] as [String: Any]
        }
        if let phone {
            result["network"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(phone))
            if !settings.modulePath.isEmpty && !phone.dnsServers.isEmpty {
                let transaction = SurgeFileTransaction()
                let module = URL(fileURLWithPath: settings.modulePath, isDirectory: false).standardizedFileURL
                let profile = try SurgeConfiguration.profileURL(settings: settings, current: profileName)
                try transaction.prepare(module) { try SurgeConfiguration.module($0, dns: phone.dnsServers) }
                try transaction.prepare(profile) { try SurgeConfiguration.profile($0, interface: phone.interface) }
                result["would_modify"] = transaction.changes.map { $0.url.lastPathComponent }
            }
        }
        let output = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: output, as: UTF8.self))
    }
}
