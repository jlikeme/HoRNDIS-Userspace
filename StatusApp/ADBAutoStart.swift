// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin

struct ADBUSBDevice: Equatable {
    let serial: String
    let state: String
    let model: String
    var transportID: String? = nil
}

struct ADBAutoStatus: Codable {
    var state: String
    var detail = ""
    var model: String?
    var updatedAt = Date().timeIntervalSince1970
    var startAttempts: Int?
    var lastStartAt: TimeInterval?
    var lastStartTrigger: String?
}

struct ADBHostState {
    var state: String
    var processID: Int32
    var networkReady = false
    var permitsStart: Bool { state == "waiting" }
    var running: Bool { ["waiting", "connecting", "connected"].contains(state) }

    static func read() -> ADBHostState {
        guard let data = FileManager.default.contents(atPath: "/var/run/horndis/status.json"),
              let runtime = try? JSONDecoder().decode(SurgeRuntime.self, from: data) else {
            return ADBHostState(state: "unavailable", processID: 0)
        }
        let age = Date().timeIntervalSince1970 - Double(runtime.updatedAt)
        guard age >= -2 && age <= 10, runtime.processID > 0, runtime.controlAvailable == true,
              kill(runtime.processID, 0) == 0 || errno != ESRCH else {
            return ADBHostState(state: "unavailable", processID: 0)
        }
        return ADBHostState(state: runtime.state, processID: runtime.processID)
    }
}

enum ADBStartError: LocalizedError {
    case transport(String)
    case command(String)
    var errorDescription: String? {
        switch self { case .transport(let value), .command(let value): return value }
    }
}

protocol ADBControlling {
    func devices() throws -> [ADBUSBDevice]
    func functions(_ device: ADBUSBDevice) throws -> Set<String>
    func startSharing(_ device: ADBUSBDevice) throws
}

final class ADBClient: ADBControlling {
    var configuredPath = ""

    static func executable(configuredPath: String) throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var paths = configuredPath.isEmpty ? [
            "/opt/homebrew/bin/adb", "/usr/local/bin/adb",
            home.appendingPathComponent("Library/Android/sdk/platform-tools/adb", isDirectory: false).path,
        ] : [configuredPath]
        if configuredPath.isEmpty {
            for key in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] {
                if let root = ProcessInfo.processInfo.environment[key], !root.isEmpty {
                    paths.append(URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent("platform-tools/adb", isDirectory: false).path)
                }
            }
        }
        guard let path = paths.first(where: { $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw ADBStartError.command("ADB was not found. Install Android Platform Tools or choose the adb executable in Details.")
        }
        return URL(fileURLWithPath: path, isDirectory: false)
    }

    private func command(_ arguments: [String], device: ADBUSBDevice? = nil) throws -> String {
        var environment = ProcessInfo.processInfo.environment
        // This feature controls phones on this Mac, never a redirected remote ADB server.
        for key in ["ADB_SERVER_SOCKET", "ANDROID_SERIAL", "ADB_TRACE"] { environment.removeValue(forKey: key) }
        let result: SurgeCommandResult
        let executable = try Self.executable(configuredPath: configuredPath)
        do {
            result = try SurgeProcess.run(executable, arguments,
                                          timeout: 4, environment: environment)
        } catch {
            if arguments.contains("setFunctions") {
                throw ADBStartError.transport("ADB did not acknowledge the USB mode change; waiting for the interface to appear.")
            }
            throw error
        }
        let output = device.map { result.output.replacingOccurrences(of: $0.serial, with: "USB device") } ?? result.output
        let lower = output.lowercased()
        if result.status != 0 || lower.contains("exception") || lower.contains("permission denied") || lower.contains("error:") {
            if ["device offline", "device not found", "closed", "disconnected", "no devices"].contains(where: lower.contains) {
                throw ADBStartError.transport(String(output.prefix(400)))
            }
            throw ADBStartError.command(device == nil
                ? "ADB could not list USB devices. Check the ADB executable and local connection."
                : String(output.prefix(400)))
        }
        return result.output
    }

    static func parseDevices(_ output: String) throws -> [ADBUSBDevice] {
        guard output.contains("List of devices attached") else {
            throw ADBStartError.command("ADB returned an invalid device list.")
        }
        var devices = [ADBUSBDevice]()
        for line in output.components(separatedBy: .newlines) {
            let fields = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard fields.count >= 2, fields.dropFirst(2).contains(where: { $0.hasPrefix("usb:") }) else { continue }
            let model = fields.first(where: { $0.hasPrefix("model:") }).map { String($0.dropFirst(6)).replacingOccurrences(of: "_", with: " ") } ?? "Android"
            let transport = fields.first(where: { $0.hasPrefix("transport_id:") }).map { String($0.dropFirst(13)) }
            devices.append(ADBUSBDevice(serial: fields[0], state: fields[1], model: model, transportID: transport))
        }
        guard Set(devices.map(\.serial)).count == devices.count else {
            throw ADBStartError.command("ADB reported ambiguous USB device identifiers.")
        }
        return devices
    }

    func devices() throws -> [ADBUSBDevice] { try Self.parseDevices(command(["devices", "-l"])) }
    func functions(_ device: ADBUSBDevice) throws -> Set<String> {
        let output = try command(["-s", device.serial, "shell", "svc", "usb", "getFunctions"], device: device)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if output.isEmpty || output == "none" { return [] }
        let values = output.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard values.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 95 } }) else {
            throw ADBStartError.command("Cannot read the phone's USB functions. This Android version may not support svc usb getFunctions.")
        }
        return Set(values)
    }
    func startSharing(_ device: ADBUSBDevice) throws {
        _ = try command(["-s", device.serial, "shell", "svc", "usb", "setFunctions", "rndis"], device: device)
    }
}

final class ADBAutoCoordinator {
    private struct Attachment {
        var lastSeen: TimeInterval
        var transportID: String?
        var trigger = "usbDetected"
        var handled = false
        var startedAt: TimeInterval?
        var failure = ""
        var modeConfirmed = false
        var startedTransportID: String?
    }
    let controller: ADBControlling
    private var attachments = [String: Attachment]()
    private var retryToken: String?
    private var discoveryTrigger = "usbDetected"
    private(set) var startAttempts = 0
    private(set) var lastStartAt: TimeInterval?
    private(set) var lastStartTrigger: String?
    static let disconnectGrace: TimeInterval = 8
    static let startTimeout: TimeInterval = 30

    init(controller: ADBControlling) { self.controller = controller }

    func reconcile(settings: SurgeSettings, host: ADBHostState, now: TimeInterval,
                   stillAllowed: () -> Bool) throws -> ADBAutoStatus {
        guard settings.autoStartUSB else {
            attachments.removeAll(); retryToken = settings.adbRetryToken
            return ADBAutoStatus(state: "off")
        }
        if retryToken != settings.adbRetryToken {
            if retryToken != nil { discoveryTrigger = "explicitRetry" }
            attachments.removeAll(); retryToken = settings.adbRetryToken
        }
        if host.state == "paused" || settings.adbPausedProcessID == host.processID { return ADBAutoStatus(state: "paused") }
        guard host.running else { return ADBAutoStatus(state: "waitingService") }
        let devices = try controller.devices()
        let present = Set(devices.map(\.serial))
        attachments = attachments.filter { present.contains($0.key) || now - $0.value.lastSeen < Self.disconnectGrace }
        for device in devices {
            if var entry = attachments[device.serial] {
                if let transport = device.transportID, transport != entry.transportID {
                    // A short cable reconnect is a new ADB transport even when the
                    // serial is unchanged. Only our own unconfirmed mode switch
                    // inherits the old attempt during its bounded re-enumeration.
                    let ownModeChange = entry.startedAt.map { now - $0 < Self.startTimeout } == true &&
                        entry.failure.isEmpty && !entry.modeConfirmed
                    if !ownModeChange {
                        entry = Attachment(lastSeen: now, transportID: transport, trigger: "usbTransportChanged")
                    }
                    entry.transportID = transport
                }
                entry.lastSeen = now
                attachments[device.serial] = entry
            } else {
                attachments[device.serial] = Attachment(lastSeen: now, transportID: device.transportID, trigger: discoveryTrigger)
            }
        }
        if !devices.isEmpty { discoveryTrigger = "usbDetected" }
        guard !devices.isEmpty else { return ADBAutoStatus(state: "waitingDevice") }
        guard devices.count == 1 else { return ADBAutoStatus(state: "multipleDevices") }
        let device = devices[0]
        guard device.state == "device" else {
            return ADBAutoStatus(state: device.state == "unauthorized" ? "unauthorized" : "offline", model: device.model)
        }
        var entry = attachments[device.serial]!
        let functions: Set<String>
        do { functions = try controller.functions(device) }
        catch {
            if let started = entry.startedAt, now - started < Self.startTimeout {
                return ADBAutoStatus(state: "starting", model: device.model)
            }
            throw error
        }
        if functions.contains("rndis") {
            entry.handled = true
            entry.modeConfirmed = entry.modeConfirmed || host.networkReady ||
                (entry.startedAt != nil && entry.transportID != nil && entry.transportID != entry.startedTransportID)
            attachments[device.serial] = entry
            if host.networkReady { return ADBAutoStatus(state: "shared", model: device.model) }
            if let started = entry.startedAt, now - started >= Self.startTimeout {
                return ADBAutoStatus(state: "failed", detail: "RNDIS is enabled, but the phone did not provide a working DHCP/DNS configuration. Check USB tethering on the phone.", model: device.model)
            }
            return ADBAutoStatus(state: "waitingNetwork", model: device.model)
        }
        if host.state != "waiting" {
            // The previous session can still look connected after a cable reset.
            // Wait for its disconnect publication without consuming the new attempt.
            return ADBAutoStatus(state: "waitingNetwork", model: device.model)
        }
        if entry.handled {
            if let started = entry.startedAt, entry.failure.isEmpty, now - started < Self.startTimeout {
                return ADBAutoStatus(state: "starting", model: device.model)
            }
            return ADBAutoStatus(state: entry.startedAt == nil ? "handled" : "failed",
                detail: !entry.failure.isEmpty ? entry.failure : (entry.startedAt == nil
                    ? "This USB connection has already been handled. Reconnect the phone or use Retry USB Start."
                    : "The phone did not expose RNDIS within 30 seconds. Enable USB tethering manually or use Retry USB Start."),
                model: device.model)
        }
        guard stillAllowed() else { return ADBAutoStatus(state: "waitingService", model: device.model) }
        entry.handled = true
        entry.startedAt = now
        entry.startedTransportID = device.transportID
        attachments[device.serial] = entry
        startAttempts += 1
        lastStartAt = Date().timeIntervalSince1970
        lastStartTrigger = entry.trigger
        do { try controller.startSharing(device) }
        catch ADBStartError.transport(_) {
            // USB re-enumeration may close ADB before the command can acknowledge.
        } catch {
            entry.failure = error.localizedDescription
            attachments[device.serial] = entry
            return ADBAutoStatus(state: "failed", detail: entry.failure, model: device.model)
        }
        return ADBAutoStatus(state: "starting", model: device.model)
    }
}

final class ADBAutoService: @unchecked Sendable {
    private let storage: SurgeStorage
    private let allowed: @Sendable () -> Bool
    private let queue = DispatchQueue(label: "io.github.noahhhi.horndis.adb")
    private let client = ADBClient()
    private var timer: DispatchSourceTimer?
    private var coordinator: ADBAutoCoordinator?
    private var observer: SurgeNetworkObserver?
    private var nextPoll: TimeInterval = 0
    private var lastPublish: TimeInterval = 0
    private var previousSettings: SurgeSettings?
    private var failures = 0
    private var probedNetwork: SurgePhoneNetwork?
    private var dnsReady = false
    private var lastDNSProbe: TimeInterval = 0
    private var dnsProbeDetail = ""
    private var dnsPermissionDenied = false
    private var report = ADBAutoStatus(state: "off")
    private var loggedState = ""
    private var publicationError = ""
    private let stopLock = NSLock()
    private var stopped = false
    private var mayRun: Bool {
        stopLock.lock(); let active = !stopped; stopLock.unlock()
        return active && allowed()
    }

    init(storage: SurgeStorage, allowed: @escaping @Sendable () -> Bool) {
        self.storage = storage; self.allowed = allowed
    }
    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1, leeway: .milliseconds(150))
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        timer.resume()
    }
    func stop() {
        stopLock.lock(); stopped = true; stopLock.unlock()
        timer?.cancel(); timer = nil
        let done = DispatchSemaphore(value: 0)
        queue.async { done.signal() }
        _ = done.wait(timeout: .now() + 6)
    }
    private func tick() {
        guard mayRun else { return }
        let now = ProcessInfo.processInfo.systemUptime
        do {
            let settings = try storage.settings()
            let configurationChanged = previousSettings?.autoStartUSB != settings.autoStartUSB || previousSettings?.adbPath != settings.adbPath
            if configurationChanged {
                coordinator = ADBAutoCoordinator(controller: client)
            }
            if configurationChanged || previousSettings?.adbRetryToken != settings.adbRetryToken {
                nextPoll = 0; failures = 0
            }
            previousSettings = settings
            client.configuredPath = settings.adbPath
            if now >= nextPoll {
                var host = ADBHostState.read()
                if settings.adbPausedProcessID == host.processID { host.state = "paused" }
                if settings.autoStartUSB && host.state == "connected" {
                    if observer == nil { observer = try SurgeNetworkObserver() }
                    if let network = try observer?.snapshot() {
                        if network != probedNetwork || now - lastDNSProbe >= (dnsReady ? 60 : 5) {
                            let probe = SurgeDNSProbe.check(network)
                            dnsReady = probe.ready
                            dnsProbeDetail = probe.ready ? "" : probe.detail
                            dnsPermissionDenied = probe.localNetworkDenied
                            probedNetwork = network
                            lastDNSProbe = now
                        }
                        host.networkReady = dnsReady
                    }
                }
                if coordinator == nil { coordinator = ADBAutoCoordinator(controller: client) }
                let processID = host.processID
                report = try coordinator!.reconcile(settings: settings, host: host, now: now, stillAllowed: {
                    guard self.mayRun, let latest = try? self.storage.settings(), latest.autoStartUSB,
                          latest.adbPath == settings.adbPath, latest.adbRetryToken == settings.adbRetryToken else { return false }
                    let current = ADBHostState.read()
                    return current.permitsStart && current.processID == processID && latest.adbPausedProcessID != processID
                })
                if report.state == "waitingNetwork" && host.state == "connected" {
                    report.detail = dnsProbeDetail
                    if dnsPermissionDenied { report.state = "localNetworkDenied" }
                }
                failures = 0; nextPoll = ProcessInfo.processInfo.systemUptime + 2; lastPublish = 0
            }
        } catch {
            failures += 1
            nextPoll = ProcessInfo.processInfo.systemUptime + [2.0, 5, 10, 30][min(failures - 1, 3)]
            report = ADBAutoStatus(state: "failed", detail: error.localizedDescription)
            lastPublish = 0
        }
        if now - lastPublish >= 5 || lastPublish == 0 {
            report.startAttempts = coordinator?.startAttempts
            report.lastStartAt = coordinator?.lastStartAt
            report.lastStartTrigger = coordinator?.lastStartTrigger
            report.updatedAt = Date().timeIntervalSince1970
            let state = "adb state=\(report.state) attempts=\(report.startAttempts ?? 0) trigger=\(report.lastStartTrigger ?? "-") \(report.detail)"
            if state != loggedState { AgentRuntime.log(state, storage: storage); loggedState = state }
            do {
                try storage.save(report, to: storage.adbStatusURL)
                publicationError = ""
            } catch {
                let message = "ADB status publication failed: \(error.localizedDescription)"
                if message != publicationError { AgentRuntime.log(message, storage: storage); publicationError = message }
            }
            lastPublish = now
        }
    }

    static func inspect() throws {
        let settings = try SurgeStorage.standard.settings()
        let client = ADBClient(); client.configuredPath = settings.adbPath
        let devices = try client.devices()
        var result: [String: Any] = ["automatic_start": settings.autoStartUSB,
            "adb_path": try ADBClient.executable(configuredPath: settings.adbPath).path,
            "service_state": ADBHostState.read().state,
            "usb_devices": devices.map { ["state": $0.state, "model": $0.model] }]
        if devices.count == 1, devices[0].state == "device" {
            result["usb_functions"] = Array(try client.functions(devices[0])).sorted()
        }
        if let status = try? SurgeStorage.standard.read(ADBAutoStatus.self, from: SurgeStorage.standard.adbStatusURL,
                                                       default: ADBAutoStatus(state: "off")) {
            result["automatic_status"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(status))
        }
        print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
    }
}
