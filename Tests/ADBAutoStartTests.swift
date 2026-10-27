// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin

private enum Failure: Error { case assertion(String) }
private func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw Failure.assertion(message) }
}
private func expectFailure(_ body: () throws -> Void) throws {
    do { try body() } catch { return }
    throw Failure.assertion("Expected failure")
}

private final class FakeADB: ADBControlling {
    var list = [ADBUSBDevice(serial: "phone-1", state: "device", model: "Test Phone")]
    var currentFunctions: Set<String> = ["mtp"]
    var starts = [String]()
    var queries = 0
    var functionQueries = 0
    var startError: Error?
    var functionError: Error?
    var onFunctions: (() -> Void)?
    func devices() throws -> [ADBUSBDevice] { queries += 1; return list }
    func functions(_ device: ADBUSBDevice) throws -> Set<String> {
        functionQueries += 1; onFunctions?()
        if let functionError { throw functionError }
        return currentFunctions
    }
    func startSharing(_ device: ADBUSBDevice) throws {
        starts.append(device.serial)
        if let startError { throw startError }
    }
}

@main
private enum ADBAutoStartTests {
    static let waiting = ADBHostState(state: "waiting", processID: 123)
    static func settings() -> SurgeSettings { SurgeSettings(autoStartUSB: true) }

    static func main() throws {
        let tests: [(String, () throws -> Void)] = [
            ("existing preferences default automatic USB start off", migration),
            ("disabled feature never starts or probes ADB", disabled),
            ("authorized USB phone starts once without Surge", startOnce),
            ("authorization and offline states do not execute shell commands", authorization),
            ("multiple phones never trigger an arbitrary target", multipleDevices),
            ("device parser ignores Wi-Fi and emulator transports", parser),
            ("existing RNDIS and manual phone shutdown are respected", existingSharing),
            ("paused and stopped services block automatic startup", paused),
            ("immediate pause intent blocks startup before runtime publication", pauseIntent),
            ("state changes while probing cancel the pending command", cancelled),
            ("ADB disconnect during USB re-enumeration is not retried", reenumeration),
            ("permission errors require an explicit retry", commandFailure),
            ("command success does not imply DHCP or DNS success", readiness),
            ("failed startup times out without a retry loop", timeout),
            ("a later cable connection can make a new attempt", reconnect),
            ("native ADB uses a scoped serial and local server environment", nativeArguments),
            ("ADB-only installation does not wait for unused Surge cleanup", cleanup),
            ("quick reconnect gets a fresh attempt despite the same serial", quickReconnect),
            ("stale connected status does not consume a new attempt", staleConnectedStatus),
            ("self re-enumeration is protected until network confirmation", transportReenumeration),
            ("new USB transport can retry a previous permission failure", failedTransportReconnect),
            ("replug before DNS readiness still gets a fresh attempt", replugBeforeDNS),
        ]
        for (name, test) in tests { try test(); print("PASS: \(name)") }
        print("ADB automatic USB start: \(tests.count) tests passed")
    }

    static func migration() throws {
        let old = Data("{\"enabled\":true,\"modulePath\":\"/existing/SIM.sgmodule\",\"hasBeenEnabled\":true}".utf8)
        let value = try JSONDecoder().decode(SurgeSettings.self, from: old)
        try expect(value.enabled && !value.autoStartUSB && value.adbPath.isEmpty && value.adbRetryToken.isEmpty, "Preserve existing settings without enabling ADB")
        try expect(value.adbPausedProcessID == nil, "No stale pause intent on migration")
    }
    static func disabled() throws {
        let adb = FakeADB(); let c = ADBAutoCoordinator(controller: adb)
        let report = try c.reconcile(settings: SurgeSettings(), host: waiting, now: 0, stillAllowed: { true })
        try expect(report.state == "off" && adb.queries == 0 && adb.starts.isEmpty, "Default-off has no ADB side effects")
    }
    static func startOnce() throws {
        let adb = FakeADB(); let c = ADBAutoCoordinator(controller: adb); let s = settings()
        try expect(!s.enabled, "ADB is independent of Surge")
        for time in [0.0, 2, 4, 6] {
            let report = try c.reconcile(settings: s, host: waiting, now: time, stillAllowed: { true })
            try expect(report.state == "starting", "Wait for observed results")
        }
        try expect(adb.starts == ["phone-1"], "One mode change per connection")
    }
    static func authorization() throws {
        for state in ["unauthorized", "offline"] {
            let adb = FakeADB(); adb.list = [ADBUSBDevice(serial: "phone-1", state: state, model: "Phone")]
            let c = ADBAutoCoordinator(controller: adb)
            let report = try c.reconcile(settings: settings(), host: waiting, now: 0, stillAllowed: { true })
            try expect(report.state == state && adb.functionQueries == 0 && adb.starts.isEmpty, "Never shell into an unauthorized/offline phone")
            adb.list[0] = ADBUSBDevice(serial: "phone-1", state: "device", model: "Phone")
            _ = try c.reconcile(settings: settings(), host: waiting, now: 2, stillAllowed: { true })
            try expect(adb.starts.count == 1, "Human authorization permits a first attempt")
        }
    }
    static func multipleDevices() throws {
        let adb = FakeADB(); adb.list.append(ADBUSBDevice(serial: "phone-2", state: "device", model: "Other"))
        let report = try ADBAutoCoordinator(controller: adb).reconcile(settings: settings(), host: waiting, now: 0, stillAllowed: { true })
        try expect(report.state == "multipleDevices" && adb.functionQueries == 0 && adb.starts.isEmpty, "Do not choose between multiple phones")
    }
    static func parser() throws {
        let output = "* daemon started successfully *\nList of devices attached\nusb-phone device usb:123 model:Redmi_K20_Pro transport_id:2\n192.0.2.1:5555 device product:test model:Wireless\nemulator-5554 device model:Emulator\nlocked unauthorized usb:456\n"
        let devices = try ADBClient.parseDevices(output)
        try expect(devices.count == 2 && devices[0].model == "Redmi K20 Pro" && devices[0].transportID == "2" && devices[1].state == "unauthorized", "USB-only discovery including authorization and transport identity")
        try expectFailure { _ = try ADBClient.parseDevices("unexpected output") }
        try expectFailure { _ = try ADBClient.parseDevices("List of devices attached\nsame device usb:1\nsame device usb:2\n") }
    }
    static func existingSharing() throws {
        let adb = FakeADB(); adb.currentFunctions = ["rndis", "adb"]
        let c = ADBAutoCoordinator(controller: adb)
        let ready = ADBHostState(state: "connected", processID: 123, networkReady: true)
        let report = try c.reconcile(settings: settings(), host: ready, now: 0, stillAllowed: { false })
        try expect(report.state == "shared" && adb.starts.isEmpty, "Already enabled sharing is a no-op")
        adb.currentFunctions = ["mtp"]
        let manualOff = try c.reconcile(settings: settings(), host: waiting, now: 2, stillAllowed: { true })
        try expect(manualOff.state == "handled" && adb.starts.isEmpty, "Do not repeatedly undo manual phone changes")
    }
    static func paused() throws {
        for state in ["paused", "stopped", "unavailable", "starting", "error"] {
            let adb = FakeADB()
            _ = try ADBAutoCoordinator(controller: adb).reconcile(settings: settings(), host: ADBHostState(state: state, processID: 123), now: 0, stillAllowed: { true })
            try expect(adb.queries == 0 && adb.starts.isEmpty, "No ADB changes while service is paused or unavailable")
        }
        let adb = FakeADB()
        _ = try ADBAutoCoordinator(controller: adb).reconcile(settings: settings(), host: ADBHostState(state: "connecting", processID: 123), now: 0, stillAllowed: { true })
        try expect(adb.starts.isEmpty, "Do not reset USB during RNDIS initialization")
    }
    static func pauseIntent() throws {
        let adb = FakeADB(); let c = ADBAutoCoordinator(controller: adb); var s = settings()
        s.adbPausedProcessID = 123
        let report = try c.reconcile(settings: s, host: waiting, now: 0, stillAllowed: { true })
        try expect(report.state == "paused" && adb.starts.isEmpty && adb.queries == 0, "Pause intent closes the control-server publication window")
        _ = try c.reconcile(settings: s, host: ADBHostState(state: "waiting", processID: 124), now: 2, stillAllowed: { true })
        try expect(adb.starts.count == 1, "An old process pause does not suppress a restarted service")
    }
    static func cancelled() throws {
        let adb = FakeADB(); let c = ADBAutoCoordinator(controller: adb); var allowed = true
        adb.onFunctions = { allowed = false }
        _ = try c.reconcile(settings: settings(), host: waiting, now: 0, stillAllowed: { allowed })
        try expect(adb.starts.isEmpty, "Recheck settings and service state immediately before mutation")
    }
    static func reenumeration() throws {
        let adb = FakeADB(); adb.startError = ADBStartError.transport("closed")
        let c = ADBAutoCoordinator(controller: adb)
        _ = try c.reconcile(settings: settings(), host: waiting, now: 0, stillAllowed: { true })
        adb.list = []
        _ = try c.reconcile(settings: settings(), host: waiting, now: 2, stillAllowed: { true })
        adb.list = [ADBUSBDevice(serial: "phone-1", state: "device", model: "Phone")]
        _ = try c.reconcile(settings: settings(), host: waiting, now: 4, stillAllowed: { true })
        try expect(adb.starts.count == 1, "Short ADB disappearance is not a new automatic attempt")
        adb.currentFunctions = ["rndis"]
        let report = try c.reconcile(settings: settings(), host: waiting, now: 6, stillAllowed: { true })
        try expect(report.state == "waitingNetwork", "Verify RNDIS after ambiguous command completion")
    }
    static func commandFailure() throws {
        let adb = FakeADB(); adb.startError = ADBStartError.command("Permission denied")
        let c = ADBAutoCoordinator(controller: adb); var s = settings()
        for time in [0.0, 2, 4] {
            let report = try c.reconcile(settings: s, host: waiting, now: time, stillAllowed: { true })
            try expect(report.state == "failed" && report.detail.contains("Permission denied"), "Display the failure")
        }
        try expect(adb.starts.count == 1, "A permission error does not create a retry loop")
        s.adbRetryToken = "explicit-retry"
        _ = try c.reconcile(settings: s, host: waiting, now: 6, stillAllowed: { true })
        try expect(adb.starts.count == 2, "Explicit retry permits another attempt")
        try expect(c.startAttempts == 2 && c.lastStartAt != nil && c.lastStartTrigger == "explicitRetry", "Record real commands and their trigger")
    }
    static func readiness() throws {
        let adb = FakeADB(); let c = ADBAutoCoordinator(controller: adb)
        _ = try c.reconcile(settings: settings(), host: waiting, now: 0, stillAllowed: { true })
        adb.currentFunctions = ["rndis"]
        let pending = try c.reconcile(settings: settings(), host: ADBHostState(state: "connected", processID: 123), now: 2, stillAllowed: { false })
        try expect(pending.state == "waitingNetwork", "RNDIS alone does not prove the lease or DNS")
        let ready = try c.reconcile(settings: settings(), host: ADBHostState(state: "connected", processID: 123, networkReady: true), now: 4, stillAllowed: { false })
        try expect(ready.state == "shared", "Publish readiness only after observed network configuration")
    }
    static func timeout() throws {
        let adb = FakeADB(); let c = ADBAutoCoordinator(controller: adb)
        _ = try c.reconcile(settings: settings(), host: waiting, now: 0, stillAllowed: { true })
        let report = try c.reconcile(settings: settings(), host: waiting, now: 31, stillAllowed: { true })
        try expect(report.state == "failed" && report.detail.contains("30 seconds") && adb.starts.count == 1, "Report the timeout instead of repeatedly setting USB functions")
        adb.currentFunctions = ["rndis"]
        let incomplete = try c.reconcile(settings: settings(), host: waiting, now: 32, stillAllowed: { true })
        try expect(incomplete.state == "failed" && incomplete.detail.contains("DHCP/DNS"), "Detect a USB-only change without tethering services")
    }
    static func reconnect() throws {
        let adb = FakeADB(); let c = ADBAutoCoordinator(controller: adb)
        _ = try c.reconcile(settings: settings(), host: waiting, now: 0, stillAllowed: { true })
        adb.list = []
        _ = try c.reconcile(settings: settings(), host: waiting, now: 1, stillAllowed: { true })
        _ = try c.reconcile(settings: settings(), host: waiting, now: 10, stillAllowed: { true })
        adb.list = [ADBUSBDevice(serial: "phone-1", state: "device", model: "Phone")]
        _ = try c.reconcile(settings: settings(), host: waiting, now: 11, stillAllowed: { true })
        try expect(adb.starts.count == 2, "A later attachment is eligible")
    }
    static func nativeArguments() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("horndis-adb-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("adb")
        let log = root.appendingPathComponent("arguments.txt")
        let quotedLog = "'" + log.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let script = """
        #!/bin/sh
        [ -z "${ADB_SERVER_SOCKET:-}" ] || exit 9
        if [ "$1" = devices ]; then
          printf 'List of devices attached\\nserial;literal device usb:1 model:Test_Phone\\n'
        elif [ "$1" = -s ] && [ "$2" = 'serial;literal' ] && [ "$3" = shell ]; then
          printf '%s\\n' "$@" >> \(quotedLog)
          if [ "$6" = getFunctions ]; then printf 'rndis\\n'; fi
        else
          exit 8
        fi
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let old = getenv("ADB_SERVER_SOCKET").map { String(cString: $0) }
        setenv("ADB_SERVER_SOCKET", "tcp:remote.invalid:5037", 1)
        defer { if let old { setenv("ADB_SERVER_SOCKET", old, 1) } else { unsetenv("ADB_SERVER_SOCKET") } }
        let client = ADBClient(); client.configuredPath = executable.path
        let device = try client.devices()[0]
        try expect(try client.functions(device) == ["rndis"], "Read USB functions from the scoped USB target")
        try client.startSharing(device)
        let arguments = try String(contentsOf: log, encoding: .utf8)
        try expect(arguments.contains("-s\nserial;literal\nshell\nsvc\nusb\nsetFunctions\nrndis\n"), "No shell interpolation; exact authorized serial and fixed command")
    }

    static func cleanup() throws {
        var value = settings(); value.cleanupRevision = "uninstall"
        try expect(SurgeAgentManager.cleanupComplete(settings: value, journal: SurgeJournal(), policy: SurgePolicyJournal()), "Unused Surge does not block ADB-only uninstall")
        var pending = SurgeJournal(); pending.ownsModule = true
        try expect(!SurgeAgentManager.cleanupComplete(settings: value, journal: pending, policy: SurgePolicyJournal()), "A real module cleanup must finish")
        var policy = SurgePolicyJournal(); policy.profiles = ["Main"]
        try expect(!SurgeAgentManager.cleanupComplete(settings: value, journal: SurgeJournal(), policy: policy), "A real policy cleanup must finish")
    }

    static func quickReconnect() throws {
        let adb = FakeADB(); adb.list[0].transportID = "1"; adb.currentFunctions = ["rndis"]
        let c = ADBAutoCoordinator(controller: adb)
        _ = try c.reconcile(settings: settings(), host: ADBHostState(state: "connected", processID: 123, networkReady: true), now: 0, stillAllowed: { false })
        adb.list[0].transportID = "2"; adb.currentFunctions = ["mtp"]
        let report = try c.reconcile(settings: settings(), host: waiting, now: 1, stillAllowed: { true })
        try expect(report.state == "starting" && adb.starts.count == 1, "A reconnect inside eight seconds is not treated as the old handled attachment")
        try expect(c.lastStartTrigger == "usbTransportChanged", "Expose the actual reconnect trigger")
    }

    static func staleConnectedStatus() throws {
        for state in ["connected", "connecting"] {
            let adb = FakeADB(); adb.list[0].transportID = "2"
            let c = ADBAutoCoordinator(controller: adb)
            _ = try c.reconcile(settings: settings(), host: ADBHostState(state: state, processID: 123), now: 0, stillAllowed: { false })
            try expect(adb.starts.isEmpty, "Wait for old network status to settle")
            _ = try c.reconcile(settings: settings(), host: waiting, now: 2, stillAllowed: { true })
            try expect(adb.starts.count == 1, "The new attachment retains its startup opportunity")
        }
    }

    static func transportReenumeration() throws {
        let adb = FakeADB(); adb.list[0].transportID = "1"
        let c = ADBAutoCoordinator(controller: adb)
        _ = try c.reconcile(settings: settings(), host: waiting, now: 0, stillAllowed: { true })
        for (transport, time) in [("2", 2.0), ("3", 4.0)] {
            adb.list[0].transportID = transport
            _ = try c.reconcile(settings: settings(), host: waiting, now: time, stillAllowed: { true })
        }
        try expect(adb.starts.count == 1, "Do not repeat an unconfirmed mode-change command")
        adb.currentFunctions = ["rndis"]
        _ = try c.reconcile(settings: settings(), host: ADBHostState(state: "connected", processID: 123, networkReady: true), now: 6, stillAllowed: { false })
        adb.list[0].transportID = "4"; adb.currentFunctions = ["mtp"]
        _ = try c.reconcile(settings: settings(), host: waiting, now: 7, stillAllowed: { true })
        try expect(adb.starts.count == 2, "Confirmed sharing ends self-re-enumeration protection")
    }

    static func failedTransportReconnect() throws {
        let adb = FakeADB(); adb.list[0].transportID = "1"; adb.startError = ADBStartError.command("Permission denied")
        let c = ADBAutoCoordinator(controller: adb)
        _ = try c.reconcile(settings: settings(), host: waiting, now: 0, stillAllowed: { true })
        adb.list[0].transportID = "2"; adb.startError = nil
        _ = try c.reconcile(settings: settings(), host: waiting, now: 2, stillAllowed: { true })
        try expect(adb.starts.count == 2, "A fresh attachment is not suppressed by an old explicit failure")
    }

    static func replugBeforeDNS() throws {
        let adb = FakeADB(); adb.list[0].transportID = "1"
        let c = ADBAutoCoordinator(controller: adb)
        _ = try c.reconcile(settings: settings(), host: waiting, now: 0, stillAllowed: { true })
        adb.list[0].transportID = "2"; adb.currentFunctions = ["rndis"]
        _ = try c.reconcile(settings: settings(), host: ADBHostState(state: "connecting", processID: 123), now: 2, stillAllowed: { false })
        adb.list[0].transportID = "3"; adb.currentFunctions = ["mtp"]
        _ = try c.reconcile(settings: settings(), host: waiting, now: 3, stillAllowed: { true })
        try expect(adb.starts.count == 2, "Confirmed USB re-enumeration does not suppress a later real reconnect while DNS is pending")
    }
}
