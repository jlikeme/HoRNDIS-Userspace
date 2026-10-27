// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Darwin
import Foundation

private let horndisStatusVersion = Bundle.main.object(
    forInfoDictionaryKey: "CFBundleShortVersionString"
) as? String ?? "development"
private let statusPath = "/var/run/horndis/status.json"
private let controlPath = "/var/run/horndis/control.sock"
private let launchAgentLabel = "io.github.noahhhi.horndis.status"
private let privilegedHelperPath = "/Library/PrivilegedHelperTools/io.github.noahhhi.horndis"
private let launchDaemonPath = "/Library/LaunchDaemons/io.github.noahhhi.horndis.plist"
private let launchDaemonLabel = "io.github.noahhhi.horndis"
private let bugReportURL = URL(
    string: "https://github.com/noahhhi/HoRNDIS-Userspace/issues/new?template=bug_report.yml"
)!

private func localized(_ key: String, fallback: String) -> String {
    NSLocalizedString(key,
                      tableName: "Localizable",
                      bundle: .main,
                      value: fallback,
                      comment: "")
}

private enum ServiceAuthorizationState: Equatable {
    case granted
    case required

    var warningTitle: String? {
        switch self {
        case .granted:
            return nil
        case .required:
            return localized("authorization.required", fallback: "Authorization: Required")
        }
    }

    var symbol: String {
        switch self {
        case .granted:
            return "checkmark.shield"
        case .required:
            return "exclamationmark.shield"
        }
    }
}

private enum ServiceAuthorizationManager {
    static var state: ServiceAuthorizationState {
        guard secureRegularFile(at: privilegedHelperPath, mustBeExecutable: true),
              secureRegularFile(at: launchDaemonPath, mustBeExecutable: false),
              launchDaemonConfigurationIsValid() else {
            return .required
        }
        return .granted
    }

    private static func secureRegularFile(at path: String,
                                          mustBeExecutable: Bool) -> Bool {
        var information = stat()
        guard Darwin.lstat(path, &information) == 0,
              information.st_uid == 0,
              (information.st_mode & S_IFMT) == S_IFREG,
              (information.st_mode & (S_IWGRP | S_IWOTH)) == 0 else {
            return false
        }
        return !mustBeExecutable || (information.st_mode & S_IXUSR) != 0
    }

    private static func launchDaemonConfigurationIsValid() -> Bool {
        guard let data = FileManager.default.contents(atPath: launchDaemonPath),
              let object = try? PropertyListSerialization.propertyList(from: data,
                                                                       options: [],
                                                                       format: nil),
              let configuration = object as? [String: Any],
              configuration["Label"] as? String == launchDaemonLabel,
              let arguments = configuration["ProgramArguments"] as? [String],
              arguments.first == privilegedHelperPath else {
            return false
        }
        return true
    }

    private static func sourceToolURL() -> URL? {
        guard let resources = Bundle.main.resourceURL else {
            return nil
        }
        let tool = resources.appendingPathComponent("horndis").standardizedFileURL
        var information = stat()
        if Darwin.lstat(tool.path, &information) == 0,
           (information.st_mode & S_IFMT) == S_IFREG,
           (information.st_mode & S_IXUSR) != 0,
           (information.st_mode & (S_IWGRP | S_IWOTH)) == 0 {
            return tool
        }
        return nil
    }

    private static func appleScriptLiteral(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    static func requestInstallation() throws {
        guard let toolURL = sourceToolURL() else {
            throw NSError(domain: "HoRNDISStatus",
                          code: Int(ENOENT),
                          userInfo: [NSLocalizedDescriptionKey:
                              localized("error.bundledToolMissingOrUnsafe",
                                        fallback: "The bundled HoRNDIS network tool is missing or unsafe")])
        }

        let source = """
        set networkTool to "\(appleScriptLiteral(toolURL.path))"
        do shell script (quoted form of networkTool & " service install") with administrator privileges
        """
        guard let script = NSAppleScript(source: source) else {
            throw NSError(domain: "HoRNDISStatus",
                          code: Int(EINVAL),
                          userInfo: [NSLocalizedDescriptionKey:
                              localized("error.cannotPrepareAuthorization",
                                        fallback: "Cannot prepare the administrator authorization request")])
        }

        var errorInformation: NSDictionary?
        _ = script.executeAndReturnError(&errorInformation)
        if let errorInformation {
            let number = errorInformation[NSAppleScript.errorNumber] as? Int
            let fallback = errorInformation[NSAppleScript.errorMessage] as? String
            let message = number == -128
                ? localized("error.authorizationCancelled",
                            fallback: "Administrator authorization was cancelled")
                : fallback ?? localized("error.authorizationFailed",
                                        fallback: "Administrator authorization failed")
            throw NSError(domain: "HoRNDISStatus",
                          code: number ?? Int(EPERM),
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

}

private struct RuntimeStatus: Decodable {
    let schemaVersion: Int
    let state: String
    let device: String
    let deviceAddress: String
    let hostInterface: String
    let detail: String
    let receivedBytes: UInt64
    let transmittedBytes: UInt64
    let connectedSince: UInt64
    let controlAvailable: Bool?
    let updatedAt: UInt64
    let processID: Int

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case state
        case device
        case deviceAddress = "device_address"
        case hostInterface = "host_interface"
        case detail
        case receivedBytes = "received_bytes"
        case transmittedBytes = "transmitted_bytes"
        case connectedSince = "connected_since"
        case controlAvailable = "control_available"
        case updatedAt = "updated_at"
        case processID = "process_id"
    }
}

private enum DisplayState: Equatable {
    case connected
    case connecting
    case waiting
    case paused
    case error
    case stopped
    case unavailable
}

private struct Snapshot {
    let runtime: RuntimeStatus?
    let state: DisplayState
    let ipAddress: String?
    let message: String
}

private func ipv4Address(for interfaceName: String) -> String? {
    var interfaces: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&interfaces) == 0, let first = interfaces else {
        return nil
    }
    defer { freeifaddrs(interfaces) }

    var cursor: UnsafeMutablePointer<ifaddrs>? = first
    while let current = cursor {
        let record = current.pointee
        if String(cString: record.ifa_name) == interfaceName,
           let address = record.ifa_addr,
           address.pointee.sa_family == UInt8(AF_INET) {
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(address,
                                     socklen_t(address.pointee.sa_len),
                                     &host,
                                     socklen_t(host.count),
                                     nil,
                                     0,
                                     NI_NUMERICHOST)
            if result == 0 {
                return String(cString: host)
            }
        }
        cursor = record.ifa_next
    }
    return nil
}

private func readSnapshot() -> Snapshot {
    guard let data = FileManager.default.contents(atPath: statusPath),
          let runtime = try? JSONDecoder().decode(RuntimeStatus.self, from: data) else {
        return Snapshot(runtime: nil,
                        state: .unavailable,
                        ipAddress: nil,
                        message: localized("status.unavailable",
                                           fallback: "Service status unavailable"))
    }

    let address = runtime.hostInterface.isEmpty ? nil : ipv4Address(for: runtime.hostInterface)
    let age = Date().timeIntervalSince1970 - Double(runtime.updatedAt)
    if age > 10 {
        return Snapshot(runtime: runtime,
                        state: .unavailable,
                        ipAddress: address,
                        message: localized("status.stale", fallback: "Service status is stale"))
    }

    let displayState: DisplayState
    let message: String
    switch runtime.state {
    case "connected":
        displayState = .connected
        message = address == nil
            ? localized("status.configuringDHCP", fallback: "Configuring DHCP")
            : localized("status.connected", fallback: "USB tethering connected")
    case "connecting":
        displayState = .connecting
        message = localized("status.connecting", fallback: "Connecting")
    case "waiting":
        displayState = .waiting
        message = localized("status.waiting", fallback: "Waiting for USB tethering")
    case "paused":
        displayState = .paused
        message = localized("status.paused", fallback: "Connection paused")
    case "error":
        displayState = .error
        message = localized("status.error", fallback: "Service error")
    case "stopped":
        displayState = .stopped
        message = localized("status.stopped", fallback: "Service stopped")
    default:
        displayState = .unavailable
        message = localized("status.unknown", fallback: "Unknown service state")
    }
    return Snapshot(runtime: runtime, state: displayState, ipAddress: address, message: message)
}

private enum LaunchAgentManager {
    private static let bundleIdentifier = "io.github.noahhhi.horndis.status"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(launchAgentLabel).plist")
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    static func executablePath() -> String {
        let argument = CommandLine.arguments[0]
        let absoluteURL: URL
        if argument.hasPrefix("/") {
            absoluteURL = URL(fileURLWithPath: argument)
        } else {
            absoluteURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(argument)
        }
        // Preserve the installed application path instead of resolving bundle aliases.
        return absoluteURL.standardizedFileURL.path
    }

    static func writeConfiguration() throws {
        let directory = plistURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true,
                                                attributes: nil)
        let configuration: [String: Any] = [
            "Label": launchAgentLabel,
            "ProgramArguments": [executablePath()],
            "RunAtLoad": true,
            "LimitLoadToSessionType": "Aqua",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: configuration,
                                                      format: .xml,
                                                      options: 0)
        try data.write(to: plistURL, options: .atomic)
    }

    static func removeConfiguration() throws {
        if isInstalled {
            try FileManager.default.removeItem(at: plistURL)
        }
    }

    @discardableResult
    static func runLaunchctl(_ arguments: [String],
                             allowFailure: Bool = false) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 && !allowFailure {
            let message = String(
                format: localized("error.launchctlExited",
                                  fallback: "launchctl exited with status %d"),
                process.terminationStatus
            )
            throw NSError(domain: "HoRNDISStatus",
                          code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
        return process.terminationStatus
    }

    static var isLoaded: Bool {
        let target = "gui/\(getuid())/\(launchAgentLabel)"
        return (try? runLaunchctl(["print", target], allowFailure: true)) == 0
    }

    static var isRunning: Bool {
        NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        ).contains { $0.processIdentifier != getpid() }
    }

    static func terminateOtherInstances() {
        var applications = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        ).filter { $0.processIdentifier != getpid() }
        guard !applications.isEmpty else { return }

        for application in applications {
            application.terminate()
        }
        let gracefulDeadline = Date().addingTimeInterval(3)
        while Date() < gracefulDeadline {
            applications = applications.filter { !$0.isTerminated }
            if applications.isEmpty { return }
            Thread.sleep(forTimeInterval: 0.05)
        }

        for application in applications where !application.isTerminated {
            application.forceTerminate()
        }
        let forcedDeadline = Date().addingTimeInterval(2)
        while Date() < forcedDeadline && applications.contains(where: { !$0.isTerminated }) {
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    static func openOnce() throws {
        guard !isRunning else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", Bundle.main.bundleURL.path]
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let message = String(
                format: localized("error.openExited",
                                  fallback: "open exited with status %d"),
                process.terminationStatus
            )
            throw NSError(domain: "HoRNDISStatus",
                          code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    static func start() throws {
        guard isInstalled else {
            try openOnce()
            return
        }
        let target = "gui/\(getuid())/\(launchAgentLabel)"
        if !isLoaded {
            terminateOtherInstances()
            try runLaunchctl(["bootstrap", "gui/\(getuid())", plistURL.path])
        }
        try runLaunchctl(["kickstart", target])
    }

    static func stop() throws {
        let target = "gui/\(getuid())/\(launchAgentLabel)"
        try runLaunchctl(["bootout", target], allowFailure: true)
        terminateOtherInstances()
    }

    static func restart() throws {
        try stop()
        try start()
    }

    static func installAndStart() throws {
        try writeConfiguration()
        let target = "gui/\(getuid())/\(launchAgentLabel)"
        try runLaunchctl(["bootout", target], allowFailure: true)
        terminateOtherInstances()
        try runLaunchctl(["bootstrap", "gui/\(getuid())", plistURL.path])
        try runLaunchctl(["kickstart", "-k", target])
    }

    static func uninstall() throws {
        let target = "gui/\(getuid())/\(launchAgentLabel)"
        try runLaunchctl(["bootout", target], allowFailure: true)
        try removeConfiguration()
    }
}

private enum ControlClient {
    static func send(_ command: String) throws {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw NSError(domain: "HoRNDISStatus",
                          code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey:
                              localized("error.cannotCreateControlSocket",
                                        fallback: "Cannot create the control socket")])
        }
        defer { Darwin.close(descriptor) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let pathBytes = Array(controlPath.utf8CString)
        let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count <= pathCapacity else {
            throw NSError(domain: "HoRNDISStatus",
                          code: Int(ENAMETOOLONG),
                          userInfo: [NSLocalizedDescriptionKey:
                              localized("error.controlSocketPathTooLong",
                                        fallback: "Control socket path is too long")])
        }
        controlPath.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) { pointer in
                pointer.withMemoryRebound(to: CChar.self,
                                          capacity: pathCapacity) {
                    _ = strlcpy($0, source, pathCapacity)
                }
            }
        }
        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.connect(descriptor,
                               socketAddress,
                               socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            throw NSError(domain: "HoRNDISStatus",
                          code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey:
                              localized("error.cannotContactService",
                                        fallback: "Cannot contact the HoRNDIS service")])
        }
        let bytes = Array(command.utf8)
        let written = bytes.withUnsafeBytes { buffer in
            Darwin.write(descriptor, buffer.baseAddress, buffer.count)
        }
        guard written == bytes.count else {
            throw NSError(domain: "HoRNDISStatus",
                          code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey:
                              localized("error.cannotSendConnectionRequest",
                                        fallback: "Cannot send the connection request")])
        }
    }
}

private enum NativeMenuTag: Int {
    case status = 100
    case device
    case traffic
    case authorization
    case authorize
    case connection
    case autoStartUSB
    case launchAtLogin
    case surge
    case details
    case detailIP = 200
    case detailInterface
    case detailMAC
    case detailPID
    case detailMessage
    case detailError
    case detailADBState
    case detailADBError
    case detailADBPath
    case retryADB
    case surgeEnabled = 300
    case surgePolicyEnabled
    case surgePolicySelection
    case surgeStatus
    case surgeInterface
    case surgeDNS
    case surgeGateway
    case surgeModulePath
    case surgeProfilePath
    case surgeError
}

@MainActor
private final class StatusAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var timer: Timer?
    private var snapshot = readSnapshot()
    private var authorizationState = ServiceAuthorizationManager.state
    private var interfaceError: String?
    private var pendingConnectionState: Bool?
    private var pendingConnectionStartedAt: Date?
    private var menuIsOpen = false
    private var shouldRefreshOnClosedTick = false
    private var displayedStatusState: DisplayState?
    private var displayedStatusMessage: String?
    private var didFinishLaunching = false
    private var localNetworkProbeInProgress = false
    private var localNetworkProbeRequested = false

    override init() {
        super.init()
        updateStatusItem()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !didFinishLaunching else { return }
        didFinishLaunching = true
        LaunchAgentManager.terminateOtherInstances()
        NSApp.setActivationPolicy(.accessory)
        refresh()
        configureNativeMenu()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            do { try SurgeAgentManager.restoreIfNeeded() }
            catch {
                let message = error.localizedDescription
                DispatchQueue.main.async {
                    self?.interfaceError = message
                    self?.updateNativeVisibleContent()
                }
            }
        }
        let refreshTimer = Timer(timeInterval: 1,
                                 target: self,
                                 selector: #selector(timerTick),
                                 userInfo: nil,
                                 repeats: true)
        refreshTimer.tolerance = 0.1
        RunLoop.main.add(refreshTimer, forMode: .default)
        RunLoop.main.add(refreshTimer, forMode: .eventTracking)
        timer = refreshTimer
    }

    @objc private func timerTick() {
        if menuIsOpen {
            refresh()
            return
        }
        shouldRefreshOnClosedTick.toggle()
        if shouldRefreshOnClosedTick {
            refresh()
        }
    }

    @objc private func refresh() {
        snapshot = readSnapshot()
        if menuIsOpen && snapshot.state == .connected {
            // A short renewable lease keeps visible traffic counters at the
            // menu's one-second cadence. If the menu closes or the app exits,
            // the service automatically returns to its low-write cadence.
            try? ControlClient.send("observe\n")
        }
        authorizationState = ServiceAuthorizationManager.state
        requestLocalNetworkAccessIfNeeded()
        if let pending = pendingConnectionState {
            let reachedRequestedState = pending
                ? snapshot.state != .paused && snapshot.state != .stopped
                : snapshot.state == .paused || snapshot.state == .stopped
            let requestExpired = pendingConnectionStartedAt.map {
                Date().timeIntervalSince($0) > 5
            } ?? true
            if reachedRequestedState || requestExpired {
                pendingConnectionState = nil
                pendingConnectionStartedAt = nil
            }
        }
        updateStatusItem()
        if menuIsOpen {
            updateNativeVisibleContent()
        }
    }

    private func nativeSymbol(_ name: String) -> NSImage? {
        let image = (NSImage(systemSymbolName: name, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "circle", accessibilityDescription: nil))
        image?.isTemplate = true
        return image
    }

    private func requestLocalNetworkAccessIfNeeded() {
        guard !localNetworkProbeRequested && !localNetworkProbeInProgress,
              snapshot.state == .connected, snapshot.ipAddress != nil,
              let settings = try? SurgeStorage.standard.settings(), settings.enabled || settings.autoStartUSB else { return }
        localNetworkProbeInProgress = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var attempted = false
            do {
                if let network = try SurgeNetworkObserver().snapshot(), !network.dnsServers.isEmpty {
                    attempted = true
                    _ = SurgeDNSProbe.check(network)
                }
            } catch { }
            let didAttempt = attempted
            DispatchQueue.main.async {
                self?.localNetworkProbeInProgress = false
                self?.localNetworkProbeRequested = didAttempt
            }
        }
    }

    private func setNativeImage(_ symbol: String, on item: NSMenuItem) {
        item.image = nativeSymbol(symbol)

        // macOS 27 lets the system hide menu-item images while their visibility
        // remains automatic. Ask AppKit to keep these semantic icons visible.
        // Use the public Objective-C setter dynamically so this source continues
        // to compile with pre-macOS-27 SDKs and still runs unchanged on macOS 11+.
        let visibilitySelector = NSSelectorFromString("setPreferredImageVisibility:")
        if item.responds(to: visibilitySelector) {
            item.setValue(1, forKey: "preferredImageVisibility")
        }
    }

    private func setNativeOffStateImage(_ symbol: String, on item: NSMenuItem) {
        item.image = nil
        item.state = .off
        item.offStateImage = nativeSymbol(symbol)
    }

    private func nativeInfoItem(tag: NativeMenuTag) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.tag = tag.rawValue
        item.isEnabled = false
        return item
    }

    private func nativeActionItem(_ title: String,
                                  symbol: String? = nil,
                                  action: Selector,
                                  keyEquivalent: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        if let symbol {
            setNativeImage(symbol, on: item)
        }
        return item
    }

    private func nativeStateItem(tag: NativeMenuTag,
                                 title: String,
                                 action: Selector) -> NSMenuItem {
        let item = nativeActionItem(title, action: action)
        item.tag = tag.rawValue
        item.state = .off
        return item
    }

    private func configureNativeMenu() {
        let menu = NSMenu(title: "HoRNDIS")
        menu.delegate = self
        menu.autoenablesItems = false

        menu.addItem(nativeInfoItem(tag: .status))
        menu.addItem(nativeInfoItem(tag: .device))
        menu.addItem(nativeInfoItem(tag: .traffic))
        menu.addItem(nativeInfoItem(tag: .authorization))

        let authorize = nativeActionItem(
            localized("menu.authorizeAndInstall", fallback: "Authorize and Install…"),
            action: #selector(authorizeAndInstall)
        )
        authorize.tag = NativeMenuTag.authorize.rawValue
        menu.addItem(authorize)
        menu.addItem(.separator())

        menu.addItem(nativeStateItem(
            tag: .connection,
            title: localized("menu.usbTethering", fallback: "USB Tethering"),
            action: #selector(toggleConnection(_:))
        ))
        let automaticUSB = nativeStateItem(tag: .autoStartUSB,
            title: localized("adb.autoStart", fallback: "Auto-start USB Tethering"),
            action: #selector(toggleADBAutoStart(_:)))
        automaticUSB.toolTip = localized("adb.hint",
            fallback: "Use authorized USB ADB devices to start tethering on connection. Pausing USB Tethering prevents automatic attempts.")
        menu.addItem(automaticUSB)
        menu.addItem(nativeStateItem(
            tag: .launchAtLogin,
            title: localized("menu.launchAtLogin", fallback: "Launch at Login"),
            action: #selector(toggleLaunchAtLogin(_:))
        ))

        let surge = NSMenuItem(title: localized("surge.menu", fallback: "Surge Integration"), action: nil, keyEquivalent: "")
        surge.tag = NativeMenuTag.surge.rawValue
        let surgeMenu = NSMenu(title: surge.title)
        surgeMenu.delegate = self
        surgeMenu.autoenablesItems = false
        surgeMenu.addItem(nativeStateItem(tag: .surgeEnabled,
            title: localized("surge.enabled", fallback: "Enable Integration"), action: #selector(toggleSurge(_:))))
        let policySwitch = nativeStateItem(tag: .surgePolicyEnabled,
            title: localized("surge.autoIntelligence", fallback: "Automatically Switch Intelligence"),
            action: #selector(toggleSurgePolicy(_:)))
        policySwitch.toolTip = localized("surge.intelligenceHint",
            fallback: "Phone ready: SIM-Route. Disconnected or disabled: 新加坡节点.")
        surgeMenu.addItem(policySwitch)
        for tag in [NativeMenuTag.surgeStatus, .surgePolicySelection, .surgeInterface, .surgeDNS, .surgeGateway, .surgeError] {
            surgeMenu.addItem(nativeInfoItem(tag: tag))
        }
        surgeMenu.addItem(.separator())
        surgeMenu.addItem(nativeInfoItem(tag: .surgeModulePath))
        surgeMenu.addItem(nativeActionItem(localized("surge.chooseModule", fallback: "Choose SIM DNS Module…"),
                                          action: #selector(chooseSurgeModule)))
        surgeMenu.addItem(nativeInfoItem(tag: .surgeProfilePath))
        surgeMenu.addItem(nativeActionItem(localized("surge.chooseProfile", fallback: "Choose Active Profile…"),
                                          action: #selector(chooseSurgeProfile)))
        surgeMenu.addItem(nativeActionItem(localized("surge.automaticProfile", fallback: "Detect Active Profile Automatically"),
                                          action: #selector(automaticSurgeProfile)))
        surgeMenu.addItem(.separator())
        surgeMenu.addItem(nativeActionItem(localized("surge.retry", fallback: "Retry Now"), action: #selector(retrySurge)))
        surgeMenu.addItem(nativeActionItem(localized("network.openSettings", fallback: "Open Local Network Settings…"), action: #selector(openLocalNetworkSettings)))
        surge.submenu = surgeMenu
        menu.addItem(surge)

        let details = NSMenuItem(title: localized("menu.details", fallback: "Details"),
                                 action: nil,
                                 keyEquivalent: "")
        details.tag = NativeMenuTag.details.rawValue
        let submenu = NSMenu(title: localized("menu.details", fallback: "Details"))
        submenu.delegate = self
        configureDetailsMenu(submenu)
        details.submenu = submenu
        menu.addItem(details)

        menu.addItem(.separator())
        menu.addItem(nativeActionItem(
            localized("menu.quit", fallback: "Quit HoRNDIS Status"),
            action: #selector(quit),
            keyEquivalent: "q"
        ))

        statusItem.menu = menu
        updateNativeVisibleContent()
    }

    private func configureDetailsMenu(_ menu: NSMenu) {
        menu.autoenablesItems = false
        menu.removeAllItems()
        menu.addItem(nativeInfoItem(tag: .detailIP))
        menu.addItem(nativeInfoItem(tag: .detailInterface))
        menu.addItem(nativeInfoItem(tag: .detailMAC))
        menu.addItem(nativeInfoItem(tag: .detailPID))
        menu.addItem(nativeInfoItem(tag: .detailMessage))
        menu.addItem(nativeInfoItem(tag: .detailError))
        menu.addItem(nativeInfoItem(tag: .detailADBState))
        menu.addItem(nativeInfoItem(tag: .detailADBError))
        menu.addItem(nativeInfoItem(tag: .detailADBPath))
        menu.addItem(nativeActionItem(localized("adb.choose", fallback: "Choose ADB…"), action: #selector(chooseADB)))
        let retryADB = nativeActionItem(localized("adb.retry", fallback: "Retry USB Start"), action: #selector(retryADBStart))
        retryADB.tag = NativeMenuTag.retryADB.rawValue
        menu.addItem(retryADB)
        menu.addItem(.separator())
        menu.addItem(nativeActionItem(
            localized("menu.saveDiagnosticReport", fallback: "Save Diagnostic Report…"),
            symbol: "doc.badge.plus",
            action: #selector(saveDiagnostics)
        ))
        menu.addItem(nativeActionItem(
            localized("menu.openServiceLog", fallback: "Open Service Log"),
            symbol: "doc.text",
            action: #selector(openLog)
        ))
        menu.addItem(nativeActionItem(
            localized("menu.reportBug", fallback: "Report a Bug…"),
            symbol: "exclamationmark.bubble",
            action: #selector(reportBug)
        ))
    }

    private func updateStatusItem() {
        let symbol: String
        let state: DisplayState
        if let pendingConnectionState {
            state = pendingConnectionState ? .connecting : .paused
        } else {
            state = snapshot.state
        }
        let statusChanged = displayedStatusState != state ||
            displayedStatusMessage != snapshot.message
        switch state {
        case .connected:
            symbol = "personalhotspot"
        case .connecting:
            symbol = "arrow.triangle.2.circlepath"
        case .waiting:
            symbol = "cable.connector"
        case .paused:
            symbol = "pause.circle"
        case .error:
            symbol = "exclamationmark.triangle"
        case .stopped, .unavailable:
            symbol = "network.slash"
        }
        if let button = statusItem.button,
           statusChanged || button.image == nil {
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "HoRNDIS")
                ?? NSImage(systemSymbolName: "network", accessibilityDescription: "HoRNDIS")
            image?.isTemplate = true
            button.image = image
            // Let NSStatusBarButton apply its standard template-image effects so the
            // symbol follows the actual menu bar appearance, independently of app mode.
            button.contentTintColor = nil
            button.toolTip = "HoRNDIS — \(snapshot.message)"
        }
        if statusChanged {
            displayedStatusState = state
            displayedStatusMessage = snapshot.message
        }
    }

    private func summaryContent() -> (
        status: (title: String, symbol: String),
        deviceAndDuration: (title: String, symbol: String),
        traffic: String,
        authorization: (title: String, symbol: String)?
    ) {
        let device: String
        let duration: String
        let traffic: String
        if let runtime = snapshot.runtime {
            device = runtime.device.isEmpty
                ? localized("summary.noDevice", fallback: "No device")
                : runtime.device
            let received = ByteCountFormatter.string(fromByteCount: Int64(runtime.receivedBytes),
                                                     countStyle: .binary)
            let transmitted = ByteCountFormatter.string(fromByteCount: Int64(runtime.transmittedBytes),
                                                        countStyle: .binary)
            let interval = runtime.connectedSince > 0
                ? max(0, Date().timeIntervalSince1970 - Double(runtime.connectedSince))
                : 0
            let formatter = DateComponentsFormatter()
            formatter.allowedUnits = [.day, .hour, .minute, .second]
            formatter.unitsStyle = .abbreviated
            duration = runtime.connectedSince > 0 ? formatter.string(from: interval) ?? "—" : "—"
            traffic = "\(transmitted)    ↓ \(received)"
        } else if snapshot.ipAddress != nil {
            device = "Android"
            duration = "—"
            traffic = "0 bytes    ↓ 0 bytes"
        } else {
            device = localized("summary.noDevice", fallback: "No device")
            duration = "—"
            traffic = "0 bytes    ↓ 0 bytes"
        }
        let deviceAndDuration = String(
            format: localized("summary.deviceAndDurationFormat", fallback: "%1$@ · %2$@"),
            locale: Locale.current,
            device,
            duration
        )
        let authorization = authorizationState.warningTitle.map {
            (title: $0, symbol: authorizationState.symbol)
        }
        return (
            status: (snapshot.message, "personalhotspot"),
            deviceAndDuration: (deviceAndDuration, "iphone"),
            traffic: traffic,
            authorization: authorization
        )
    }

    private func updateInfoItem(in menu: NSMenu,
                                tag: NativeMenuTag,
                                title: String?,
                                symbol: String?,
                                usesStateColumn: Bool = false) {
        guard let item = menu.item(withTag: tag.rawValue) else { return }
        item.isHidden = title == nil
        if let title {
            if item.title != title {
                item.title = title
            }
            if let symbol {
                if usesStateColumn {
                    setNativeOffStateImage(symbol, on: item)
                } else {
                    item.offStateImage = nil
                    setNativeImage(symbol, on: item)
                }
            } else {
                item.image = nil
                item.offStateImage = nil
            }
        }
    }

    private func updateNativeVisibleContent() {
        guard let menu = statusItem.menu else { return }
        let summary = summaryContent()
        updateInfoItem(in: menu, tag: .status,
                       title: summary.status.title, symbol: summary.status.symbol,
                       usesStateColumn: true)
        updateInfoItem(in: menu, tag: .device,
                       title: summary.deviceAndDuration.title,
                       symbol: summary.deviceAndDuration.symbol,
                       usesStateColumn: true)
        updateInfoItem(in: menu, tag: .traffic,
                       title: summary.traffic, symbol: "arrow.up",
                       usesStateColumn: true)
        updateInfoItem(in: menu, tag: .authorization,
                       title: summary.authorization?.title,
                       symbol: summary.authorization?.symbol ?? "exclamationmark.shield",
                       usesStateColumn: true)
        menu.item(withTag: NativeMenuTag.authorize.rawValue)?.isHidden =
            authorizationState != .required

        let serviceEnabled = snapshot.runtime != nil &&
            snapshot.state != .paused && snapshot.state != .stopped
        let displayedState = pendingConnectionState ?? serviceEnabled
        if let connection = menu.item(withTag: NativeMenuTag.connection.rawValue) {
            connection.state = displayedState ? .on : .off
            connection.isEnabled = snapshot.runtime?.controlAvailable == true
        }
        if let launchAtLogin = menu.item(withTag: NativeMenuTag.launchAtLogin.rawValue) {
            launchAtLogin.state = LaunchAgentManager.isInstalled ? .on : .off
            launchAtLogin.isEnabled = true
        }
        updateNativeDetailsContent()
        updateNativeSurgeContent()
        updateNativeADBContent()
    }

    private func updateNativeADBContent() {
        guard let root = statusItem.menu,
              let details = root.item(withTag: NativeMenuTag.details.rawValue)?.submenu else { return }
        do {
            let storage = SurgeStorage.standard
            let settings = try storage.settings()
            let report = try storage.read(ADBAutoStatus.self, from: storage.adbStatusURL,
                                         default: ADBAutoStatus(state: "waitingAgent", updatedAt: 0))
            root.item(withTag: NativeMenuTag.autoStartUSB.rawValue)?.state = settings.autoStartUSB ? .on : .off
            let state = !settings.autoStartUSB ? "off" :
                (Date().timeIntervalSince1970 - report.updatedAt > 15 || report.state == "off" ? "waitingAgent" : report.state)
            let title: String
            switch state {
            case "off": title = localized("adb.state.off", fallback: "Automatic USB Start Off")
            case "paused": title = localized("adb.state.paused", fallback: "USB Tethering Paused")
            case "waitingService": title = localized("adb.state.waitingService", fallback: "Waiting for HoRNDIS Service")
            case "waitingDevice": title = localized("adb.state.waitingDevice", fallback: "Waiting for USB Phone")
            case "multipleDevices": title = localized("adb.state.multipleDevices", fallback: "Connect One USB ADB Device")
            case "unauthorized": title = localized("adb.state.unauthorized", fallback: "Allow USB Debugging on the Phone")
            case "offline": title = localized("adb.state.offline", fallback: "Waiting for ADB Connection")
            case "starting": title = localized("adb.state.starting", fallback: "Starting USB Tethering")
            case "waitingNetwork": title = localized("adb.state.waitingNetwork", fallback: "USB Function Ready — Waiting for DHCP/DNS")
            case "shared": title = localized("adb.state.shared", fallback: "USB Tethering Ready")
            case "handled": title = localized("adb.state.handled", fallback: "This Connection Was Already Handled")
            case "failed": title = localized("adb.state.failed", fallback: "Automatic USB Start Failed")
            case "localNetworkDenied": title = localized("network.permissionDenied", fallback: "Allow Local Network Access")
            default: title = localized("adb.state.waitingAgent", fallback: "Waiting for Background Agent")
            }
            updateInfoItem(in: details, tag: .detailADBState, title: "ADB: \(title)", symbol: "cable.connector")
            updateInfoItem(in: details, tag: .detailADBError,
                title: settings.autoStartUSB && !report.detail.isEmpty ? String(report.detail.prefix(100)) : nil,
                symbol: "exclamationmark.triangle")
            details.item(withTag: NativeMenuTag.detailADBError.rawValue)?.toolTip = report.detail
            let executable = try? ADBClient.executable(configuredPath: settings.adbPath)
            let pathTitle = settings.adbPath.isEmpty
                ? localized("surge.automatic", fallback: "Automatic") : URL(fileURLWithPath: settings.adbPath).lastPathComponent
            updateInfoItem(in: details, tag: .detailADBPath, title: "ADB: \(pathTitle)", symbol: "doc")
            details.item(withTag: NativeMenuTag.detailADBPath.rawValue)?.toolTip = executable?.path ?? settings.adbPath
            details.item(withTag: NativeMenuTag.retryADB.rawValue)?.isEnabled = settings.autoStartUSB && snapshot.state != .paused
        } catch {
            updateInfoItem(in: details, tag: .detailADBError, title: error.localizedDescription, symbol: "exclamationmark.triangle")
        }
    }

    private func updateNativeSurgeContent() {
        guard let menu = statusItem.menu?.item(withTag: NativeMenuTag.surge.rawValue)?.submenu else { return }
        do {
            let storage = SurgeStorage.standard
            let settings = try storage.settings()
            let journal = try storage.journal()
            let policy = try storage.policyJournal()
            let report = try storage.read(SurgeLinkStatus.self, from: storage.statusURL,
                                          default: SurgeLinkStatus(state: "starting", updatedAt: 0))
            menu.item(withTag: NativeMenuTag.surgeEnabled.rawValue)?.state = settings.enabled ? .on : .off
            menu.item(withTag: NativeMenuTag.surgePolicyEnabled.rawValue)?.state = settings.switchIntelligence ? .on : .off
            let pending = journal.ownsModule || journal.needsFlush || journal.needsReload ||
                (settings.hasBeenEnabled && !settings.cleanupRevision.isEmpty && journal.cleanedRevision != settings.cleanupRevision)
            let state: String
            if !settings.enabled { state = pending ? "pendingDisable" : (policy.pending ? "pendingPolicy" : "off") }
            else if Date().timeIntervalSince1970 - report.updatedAt > 15 || report.state == "off" { state = "starting" }
            else { state = report.state }
            let title: String
            switch state {
            case "off": title = localized("surge.state.off", fallback: "Integration Off")
            case "waitingUSB": title = localized("surge.state.waitingUSB", fallback: "Waiting for USB Tethering")
            case "waitingDNS": title = localized("surge.state.waitingDNS", fallback: "Waiting for Phone DNS")
            case "waitingSurge": title = localized("surge.state.waitingSurge", fallback: "Waiting for Surge — Retrying")
            case "active": title = localized("surge.state.active", fallback: "SIM DNS Enabled")
            case "pendingDisable": title = localized("surge.state.pendingDisable", fallback: "SIM DNS Disable Pending")
            case "pendingPolicy": title = localized("surge.state.pendingPolicy", fallback: "Intelligence Fallback Pending")
            case "localNetworkDenied": title = localized("network.permissionDenied", fallback: "Allow Local Network Access")
            case "error": title = localized("surge.state.error", fallback: "Integration Failed — Retrying")
            default: title = localized("surge.state.starting", fallback: "Waiting for Integration Agent")
            }
            updateInfoItem(in: menu, tag: .surgeStatus, title: title, symbol: state == "active" ? "checkmark.circle" : "info.circle")
            updateInfoItem(in: menu, tag: .surgePolicySelection,
                title: report.policySelection.map { "Intelligence: \($0)" }, symbol: "arrow.triangle.branch")
            updateInfoItem(in: menu, tag: .surgeInterface,
                title: report.network.map { "\(localized("summary.interface", fallback: "Interface")): \($0.interface)" }, symbol: "network")
            updateInfoItem(in: menu, tag: .surgeDNS,
                title: report.network.map { "DNS: \($0.dnsServers.isEmpty ? "—" : $0.dnsServers.joined(separator: ", "))" }, symbol: "globe")
            updateInfoItem(in: menu, tag: .surgeGateway,
                title: report.network.map { "\(localized("surge.gateway", fallback: "Gateway")): \($0.gateway.isEmpty ? "—" : $0.gateway)" }, symbol: "network")
            let moduleName = settings.modulePath.isEmpty
                ? localized("surge.notSelected", fallback: "Not Selected") : URL(fileURLWithPath: settings.modulePath).lastPathComponent
            let profileName = settings.profilePath.isEmpty
                ? localized("surge.automatic", fallback: "Automatic") : URL(fileURLWithPath: settings.profilePath).lastPathComponent
            updateInfoItem(in: menu, tag: .surgeModulePath,
                title: "\(localized("surge.module", fallback: "Module")): \(moduleName)", symbol: "doc")
            updateInfoItem(in: menu, tag: .surgeProfilePath,
                title: "\(localized("surge.profile", fallback: "Profile")): \(profileName)", symbol: "doc")
            menu.item(withTag: NativeMenuTag.surgeModulePath.rawValue)?.toolTip = settings.modulePath
            menu.item(withTag: NativeMenuTag.surgeProfilePath.rawValue)?.toolTip = settings.profilePath
            updateInfoItem(in: menu, tag: .surgeError,
                title: state == "off" || report.detail.isEmpty ? nil : String(report.detail.prefix(100)), symbol: "exclamationmark.triangle")
            menu.item(withTag: NativeMenuTag.surgeError.rawValue)?.toolTip = report.detail
        } catch {
            updateInfoItem(in: menu, tag: .surgeError, title: error.localizedDescription, symbol: "exclamationmark.triangle")
        }
    }

    private func saveSurgeSettings(_ value: SurgeSettings) {
        var settings = value
        do {
            let previous = try SurgeStorage.standard.settings()
            settings.changed(requestCleanup: previous.enabled && !settings.enabled)
            try SurgeStorage.standard.save(settings, to: SurgeStorage.standard.settingsURL)
            interfaceError = nil
            updateNativeSurgeContent()
            updateNativeADBContent()
            DispatchQueue.global(qos: .utility).async { [weak self] in
                do { try SurgeAgentManager.restoreIfNeeded() }
                catch {
                    let message = error.localizedDescription
                    DispatchQueue.main.async {
                        self?.interfaceError = message
                        self?.updateNativeVisibleContent()
                    }
                }
            }
        } catch {
            interfaceError = error.localizedDescription
            updateNativeVisibleContent()
        }
    }

    @objc private func toggleSurge(_ sender: NSMenuItem) {
        do {
            var settings = try SurgeStorage.standard.settings()
            settings.enabled = sender.state != .on
            if settings.enabled && settings.modulePath.isEmpty {
                settings.modulePath = SurgeAgentManager.defaultModulePath
                if settings.modulePath.isEmpty { selectSurgeFile(module: true, enableAfterSelection: true); return }
            }
            saveSurgeSettings(settings)
        } catch { interfaceError = error.localizedDescription; updateNativeVisibleContent() }
    }

    @objc private func openLocalNetworkSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func toggleADBAutoStart(_ sender: NSMenuItem) {
        do {
            var settings = try SurgeStorage.standard.settings()
            settings.autoStartUSB = sender.state != .on
            saveSurgeSettings(settings)
        } catch { interfaceError = error.localizedDescription; updateNativeVisibleContent() }
    }

    @objc private func retryADBStart() {
        do {
            var settings = try SurgeStorage.standard.settings()
            guard settings.autoStartUSB else { return }
            settings.adbRetryToken = UUID().uuidString
            saveSurgeSettings(settings)
        } catch { interfaceError = error.localizedDescription; updateNativeVisibleContent() }
    }

    @objc private func chooseADB() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let foreground = NSWorkspace.shared.frontmostApplication
            if #available(macOS 14.0, *) { NSApp.activate() }
            else { NSApp.activate(ignoringOtherApps: true) }
            defer {
                if foreground?.processIdentifier != getpid() { _ = foreground?.activate(options: [.activateIgnoringOtherApps]) }
            }
            do {
                var settings = try SurgeStorage.standard.settings()
                let panel = NSOpenPanel()
                panel.title = localized("adb.choose", fallback: "Choose ADB…")
                panel.canChooseDirectories = false
                panel.allowsMultipleSelection = false
                if let executable = try? ADBClient.executable(configuredPath: settings.adbPath) {
                    panel.directoryURL = executable.deletingLastPathComponent()
                }
                guard panel.runModal() == .OK, let url = panel.url else { return }
                _ = try ADBClient.executable(configuredPath: url.path)
                settings.adbPath = url.path
                self.saveSurgeSettings(settings)
            } catch { self.interfaceError = error.localizedDescription; self.updateNativeVisibleContent() }
        }
    }

    @objc private func chooseSurgeModule() { selectSurgeFile(module: true) }
    @objc private func toggleSurgePolicy(_ sender: NSMenuItem) {
        do {
            var settings = try SurgeStorage.standard.settings()
            settings.switchIntelligence = sender.state != .on
            saveSurgeSettings(settings)
        } catch { interfaceError = error.localizedDescription; updateNativeVisibleContent() }
    }
    @objc private func chooseSurgeProfile() { selectSurgeFile(module: false) }
    @objc private func automaticSurgeProfile() {
        do {
            var settings = try SurgeStorage.standard.settings()
            settings.profilePath = ""
            saveSurgeSettings(settings)
        } catch { interfaceError = error.localizedDescription; updateNativeVisibleContent() }
    }
    @objc private func retrySurge() {
        do { saveSurgeSettings(try SurgeStorage.standard.settings()) }
        catch { interfaceError = error.localizedDescription; updateNativeVisibleContent() }
    }

    private func selectSurgeFile(module: Bool, enableAfterSelection: Bool = false) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let foreground = NSWorkspace.shared.frontmostApplication
            if #available(macOS 14.0, *) { NSApp.activate() }
            else { NSApp.activate(ignoringOtherApps: true) }
            defer {
                if foreground?.processIdentifier != getpid() { _ = foreground?.activate(options: [.activateIgnoringOtherApps]) }
            }
            do {
                var settings = try SurgeStorage.standard.settings()
                let panel = NSOpenPanel()
                panel.canChooseDirectories = false
                panel.allowsMultipleSelection = false
                panel.allowedFileTypes = module ? ["sgmodule"] : ["conf"]
                panel.title = module
                    ? localized("surge.chooseModule", fallback: "Choose SIM DNS Module…")
                    : localized("surge.chooseProfile", fallback: "Choose Active Profile…")
                let initial = module ? settings.modulePath : settings.profilePath
                let suggested = initial.isEmpty ? SurgeAgentManager.defaultModulePath : initial
                if !suggested.isEmpty { panel.directoryURL = URL(fileURLWithPath: suggested).deletingLastPathComponent() }
                guard panel.runModal() == .OK, let url = panel.url else { return }
                if module { settings.modulePath = url.path }
                else { settings.profilePath = url.path }
                if enableAfterSelection { settings.enabled = true }
                self.saveSurgeSettings(settings)
            } catch { self.interfaceError = error.localizedDescription; self.updateNativeVisibleContent() }
        }
    }

    private func updateNativeDetailsContent() {
        guard let details = statusItem.menu?.item(withTag: NativeMenuTag.details.rawValue)?.submenu
        else { return }

        if let runtime = snapshot.runtime {
            let interface = runtime.hostInterface.isEmpty ? "—" : runtime.hostInterface
            let address = snapshot.ipAddress
                ?? localized("summary.configuring", fallback: "configuring…")
            updateInfoItem(in: details, tag: .detailIP,
                           title: "IP: \(address)", symbol: "globe")
            updateInfoItem(in: details, tag: .detailInterface,
                           title: "\(localized("summary.interface", fallback: "Interface")): \(interface)",
                           symbol: "network")
            updateInfoItem(in: details, tag: .detailMAC,
                           title: runtime.deviceAddress.isEmpty
                               ? nil : "MAC: \(runtime.deviceAddress)",
                           symbol: "number")
            updateInfoItem(in: details, tag: .detailPID,
                           title: "PID: \(runtime.processID)", symbol: "gearshape")
            updateInfoItem(in: details, tag: .detailMessage,
                           title: runtime.detail.isEmpty ? nil : runtime.detail,
                           symbol: "text.bubble")
        } else {
            for tag in [NativeMenuTag.detailIP, .detailInterface, .detailMAC,
                        .detailPID, .detailMessage] {
                updateInfoItem(in: details, tag: tag, title: nil, symbol: "circle")
            }
        }
        updateInfoItem(in: details, tag: .detailError,
                       title: interfaceError, symbol: "exclamationmark.triangle")
    }

    @objc private func toggleConnection(_ sender: NSMenuItem) {
        let requestedState = sender.state != .on
        _ = setConnectionEnabled(requestedState)
        updateNativeVisibleContent()
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        let requestedState = sender.state != .on
        _ = setLaunchAtLoginEnabled(requestedState)
        updateNativeVisibleContent()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        snapshot = readSnapshot()
        authorizationState = ServiceAuthorizationManager.state
        updateStatusItem()
        updateNativeVisibleContent()
    }

    func menuWillOpen(_ menu: NSMenu) {
        if menu === statusItem.menu {
            menuIsOpen = true
            refresh()
        } else {
            updateNativeDetailsContent()
            updateNativeSurgeContent()
            updateNativeADBContent()
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        if menu === statusItem.menu {
            menuIsOpen = false
        }
    }

    @discardableResult
    private func setConnectionEnabled(_ requestedState: Bool) -> Bool {
        pendingConnectionState = requestedState
        pendingConnectionStartedAt = Date()
        updateStatusItem()
        let storage = SurgeStorage.standard
        var previousADBPause: Int32?
        var pauseRevision: String?
        var pauseError: String?
        do {
            var settings = try storage.settings()
            previousADBPause = settings.adbPausedProcessID
            let requestedPause = requestedState ? nil : snapshot.runtime.flatMap { Int32(exactly: $0.processID) }
            if (settings.autoStartUSB || previousADBPause != nil) && settings.adbPausedProcessID != requestedPause {
                settings.adbPausedProcessID = requestedPause
                settings.changed()
                try storage.save(settings, to: storage.settingsURL)
                pauseRevision = settings.revision
            }
        } catch { pauseError = error.localizedDescription }
        do {
            try ControlClient.send(requestedState ? "connect\n" : "disconnect\n")
            interfaceError = pauseError
        } catch {
            if let revision = pauseRevision, var current = try? storage.settings(), current.revision == revision {
                current.adbPausedProcessID = previousADBPause
                current.changed()
                try? storage.save(current, to: storage.settingsURL)
            }
            interfaceError = error.localizedDescription
            pendingConnectionState = nil
            pendingConnectionStartedAt = nil
            updateStatusItem()
            return false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.refresh()
        }
        return true
    }

    private func bundledNetworkToolURL() -> URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let tool = resources.appendingPathComponent("horndis").standardizedFileURL
        return FileManager.default.isExecutableFile(atPath: tool.path) ? tool : nil
    }

    private func diagnosticFilename() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "HoRNDIS-Diagnostics-\(formatter.string(from: Date())).txt"
    }

    @objc private func saveDiagnostics() {
        saveDiagnosticReport(openIssueAfterSaving: false)
    }

    @objc private func reportBug() {
        saveDiagnosticReport(openIssueAfterSaving: true)
    }

    private func saveDiagnosticReport(openIssueAfterSaving: Bool) {
        guard let toolURL = bundledNetworkToolURL() else {
            interfaceError = localized("error.bundledToolMissing",
                                       fallback: "The bundled HoRNDIS network tool is missing")
            updateNativeVisibleContent()
            return
        }

        let foregroundApplication = NSWorkspace.shared.frontmostApplication
        let applicationToRestore = foregroundApplication?.processIdentifier ==
            ProcessInfo.processInfo.processIdentifier ? nil : foregroundApplication
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        let panel = NSSavePanel()
        panel.title = localized("diagnostics.savePanelTitle",
                                fallback: "Save HoRNDIS Diagnostic Report")
        panel.nameFieldStringValue = diagnosticFilename()
        panel.allowedFileTypes = ["txt"]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else {
            if let applicationToRestore {
                _ = applicationToRestore.activate(options: [.activateIgnoringOtherApps])
            }
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let process = Process()
            process.executableURL = toolURL
            process.arguments = ["diagnostics", destination.path]
            let errorPipe = Pipe()
            process.standardOutput = FileHandle.nullDevice
            process.standardError = errorPipe
            do {
                try process.run()
                process.waitUntilExit()
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let detail = String(data: errorData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard process.terminationStatus == 0 else {
                    throw NSError(domain: "HoRNDISStatus",
                                  code: Int(process.terminationStatus),
                                  userInfo: [NSLocalizedDescriptionKey:
                                    detail?.isEmpty == false ? detail! : localized(
                                        "error.cannotCreateDiagnosticReport",
                                        fallback: "Could not create the diagnostic report")])
                }
                DispatchQueue.main.async {
                    self?.interfaceError = nil
                    NSWorkspace.shared.activateFileViewerSelecting([destination])
                    if openIssueAfterSaving {
                        NSWorkspace.shared.open(bugReportURL)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self?.interfaceError = error.localizedDescription
                    self?.updateNativeVisibleContent()
                    let alert = NSAlert()
                    alert.messageText = localized("diagnostics.failedTitle",
                                                  fallback: "Diagnostic Report Failed")
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                }
            }
        }
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/var/log/horndis.log"))
    }

    @discardableResult
    private func setLaunchAtLoginEnabled(_ shouldInstall: Bool) -> Bool {
        do {
            if shouldInstall {
                try LaunchAgentManager.writeConfiguration()
            } else {
                try LaunchAgentManager.removeConfiguration()
            }
            interfaceError = nil
        } catch {
            interfaceError = error.localizedDescription
            return false
        }
        updateNativeVisibleContent()
        return true
    }

    @objc private func authorizeAndInstall() {
        let foregroundApplication = NSWorkspace.shared.frontmostApplication
        let applicationToRestore = foregroundApplication?.processIdentifier ==
            ProcessInfo.processInfo.processIdentifier ? nil : foregroundApplication
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            if #available(macOS 14.0, *) {
                NSApp.activate()
            } else {
                NSApp.activate(ignoringOtherApps: true)
            }
            defer {
                if let applicationToRestore {
                    _ = applicationToRestore.activate(options: [.activateIgnoringOtherApps])
                }
            }
            do {
                try ServiceAuthorizationManager.requestInstallation()
                self.authorizationState = ServiceAuthorizationManager.state
                guard self.authorizationState == .granted else {
                    throw NSError(domain: "HoRNDISStatus",
                                  code: Int(EIO),
                                  userInfo: [NSLocalizedDescriptionKey:
                                      localized("error.installationNotVerified",
                                                fallback: "The privileged service installation could not be verified")])
                }
                self.interfaceError = nil
            } catch {
                self.interfaceError = error.localizedDescription
            }
            self.refresh()
        }
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}

private func writeStandardError(_ message: String) {
    if let data = (message + "\n").data(using: .utf8) {
        try? FileHandle.standardError.write(contentsOf: data)
    }
}

private func handleCommandLine() -> Bool {
    guard CommandLine.arguments.count > 1 else {
        return false
    }
    let command = CommandLine.arguments[1]
    do {
        switch command {
        case "install":
            try SurgeAgentManager.restoreIfNeeded(restart: true)
            try LaunchAgentManager.installAndStart()
            print("HoRNDIS menu bar status installed and started.")
        case "start", "open":
            try LaunchAgentManager.start()
            print("HoRNDIS menu bar status started.")
        case "stop", "quit":
            try LaunchAgentManager.stop()
            print("HoRNDIS menu bar status stopped; login startup remains configured.")
        case "restart":
            try LaunchAgentManager.restart()
            print("HoRNDIS menu bar status restarted.")
        case "status":
            print("HoRNDIS menu bar status: \(LaunchAgentManager.isRunning ? "running" : "stopped")")
            print("Launch at login: \(LaunchAgentManager.isInstalled ? "enabled" : "disabled")")
        case "uninstall":
            try SurgeAgentManager.uninstall()
            try LaunchAgentManager.uninstall()
            print("HoRNDIS menu bar status stopped and removed.")
        case "--version", "version":
            print("horndis-status \(horndisStatusVersion)")
        case "--help", "help":
            print("""
            Usage:
              horndis-status             Run the menu bar status app
              horndis-status start       Open the app without changing login startup
              horndis-status stop        Quit the app but preserve login startup
              horndis-status restart     Restart the app
              horndis-status status      Show app and login-startup status
              horndis-status install     Start now and at login (no sudo)
              horndis-status uninstall   Remove the login item
              horndis-status --version
            """)
        default:
            writeStandardError("Unknown command: \(command)")
            exit(64)
        }
    } catch {
        writeStandardError(error.localizedDescription)
        exit(1)
    }
    return true
}

@main
private enum HoRNDISStatusEntryPoint {
    static func main() {
        AgentRuntime.configureSignals()
        if handleCommandLine() {
            return
        }
        MainActor.assumeIsolated {
            let application = NSApplication.shared
            let delegate = StatusAppDelegate()
            application.delegate = delegate
            application.setActivationPolicy(.accessory)
            application.run()
        }
    }
}
