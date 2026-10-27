// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin

private enum TestFailure: Error { case failed(String) }
private func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw TestFailure.failed(message) }
}
private func fails(_ body: () throws -> Void) throws {
    do { try body() } catch { return }
    throw TestFailure.failed("Expected an error")
}

private final class FakeSurge: SurgeControlling {
    var running = true
    var enabled = false
    var available = true
    var profile = "Main"
    var mutations = [String]()
    var queries = 0
    var checks = 0
    var reloadFails = false
    var flushFailures = 0
    var timeoutAfterDisable = false
    var ignoreEnable = false
    var onEnable: (() -> Void)?
    var onCheck: (() throws -> Void)?
    var selections = ["Main": "新加坡节点", "Other": "Proxy"]
    var policyOptions = ["SIM-Route", "新加坡节点", "Proxy"]
    var policyQueries = 0
    var policyFailures = Set<String>()
    var ignorePolicyChange = false
    var onPolicyChange: ((String) -> Void)?
    var onFlush: (() -> Void)?
    func modules() throws -> SurgeModules {
        queries += 1
        if !running { throw SurgeIntegrationError.unavailable }
        return SurgeModules(enabled: enabled ? ["SIM DNS"] : [], available: available ? ["SIM DNS"] : [])
    }
    func currentProfile() throws -> String {
        if !running { throw SurgeIntegrationError.unavailable }
        return profile
    }
    func intelligenceGroup() throws -> SurgePolicyGroup {
        policyQueries += 1
        if !running { throw SurgeIntegrationError.unavailable }
        return SurgePolicyGroup(name: "Intelligence", selected: selections[profile] ?? "Proxy",
            options: policyOptions.map { SurgePolicyGroup.Option(name: $0, enabled: true) })
    }
    func selectIntelligence(_ policy: String) throws {
        mutations.append("policy:" + policy)
        if policyFailures.contains(policy) { throw SurgeIntegrationError.command("Policy selection failed") }
        if !ignorePolicyChange { selections[profile] = policy }
        onPolicyChange?(policy)
    }
    func checkProfile(_ path: String) throws {
        checks += 1
        try check(FileManager.default.fileExists(atPath: path), "Validate the staged profile")
        try onCheck?()
    }
    func reload() throws {
        mutations.append("reload")
        if reloadFails { throw SurgeIntegrationError.command("Reload failed") }
    }
    func setModuleEnabled(_ requested: Bool) throws {
        mutations.append(requested ? "enable" : "disable")
        if !(requested && ignoreEnable) { enabled = requested }
        if requested { onEnable?() }
        if !requested && timeoutAfterDisable {
            timeoutAfterDisable = false
            throw SurgeIntegrationError.command("Disable timed out after applying")
        }
    }
    func flushDNS() throws {
        mutations.append("flush")
        if flushFailures > 0 {
            flushFailures -= 1
            throw SurgeIntegrationError.command("Flush failed")
        }
        onFlush?()
    }
}

private final class Fixture {
    let root: URL
    let module: URL
    let profile: URL
    let storage: SurgeStorage
    let surge = FakeSurge()
    var settings: SurgeSettings
    let originalModule = "#!name=SIM DNS\r\n#!desc=Keep this description\r\n[Host]\r\nRULE-SET:https://example.com/rules = server:192.168.42.1 // keep\r\n*.example.net = server:192.168.42.1\r\nrouter.local = server:system\r\n"
    let originalProfile = "[General]\nloglevel = notify\n[Proxy]\n  SIM = direct, interface = bridge9, dns-follow-interface=true // preserve\nOther = direct, interface=en0\n[Rule]\nFINAL,DIRECT\n"

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("horndis-surge-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        module = root.appendingPathComponent("SIM-DNS.sgmodule")
        profile = root.appendingPathComponent("Main.conf")
        storage = SurgeStorage(directory: root.appendingPathComponent("state"))
        try Data(originalModule.utf8).write(to: module)
        try Data(originalProfile.utf8).write(to: profile)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: module.path)
        settings = SurgeSettings(enabled: true, modulePath: module.path)
        settings.changed()
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func coordinator() throws -> SurgeCoordinator { try SurgeCoordinator(controller: surge, storage: storage) }
    func phone(interface: String = "bridge9", dns: [String] = ["192.168.42.1"]) -> SurgePhoneNetwork {
        SurgePhoneNetwork(interface: interface, address: "192.168.42.2", dnsServers: dns,
                          gateway: "192.168.42.1", session: "100:200")
    }
    func contents(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }
    func backup(_ url: URL) -> URL { URL(fileURLWithPath: url.path + ".horndis-backup") }
    func stamp(_ url: URL) throws -> String {
        let metadata = try FileManager.default.attributesOfItem(atPath: url.path)
        return "\(metadata[.systemFileNumber]!) \(metadata[.modificationDate]!)"
    }
}

@main
private enum SurgeIntegrationTests {
    static func main() throws {
        let tests: [(String, () throws -> Void)] = [
            ("unchanged files and enabled module are a complete no-op", noOp),
            ("only DNS differences modify the module", dnsChange),
            ("only interface differences modify the profile", interfaceChange),
            ("module state is independent of file equality", enableOnly),
            ("disconnect and DNS loss disable and flush once", disconnect),
            ("pending disable survives Surge absence and worker restart", pendingDisable),
            ("ambiguous command completion is recovered", disableTimeout),
            ("cache failure retries without file writes or toggles", flushFailure),
            ("reload failure restores original files", rollback),
            ("concurrent edits are preserved without reload", concurrentEdit),
            ("disconnect during enable cannot leave the module enabled", disconnectDuringEnable),
            ("stale work cannot write files", cancelledWork),
            ("profile switches cancel pending edits", profileSwitch),
            ("invalid configuration disables the old module", invalidConfiguration),
            ("duplicate module names cannot target the wrong file", duplicateModules),
            ("enable success is verified by readback", enableReadback),
            ("default off leaves manually managed modules alone", defaultOff),
            ("semantic equality preserves whitespace and CRLF", formatting),
            ("configuration scope and symlinks are checked", scope),
            ("DHCP option lists and runtime freshness", leaseParsing),
            ("DNS replies require matching, complete real answers", dnsReplies),
            ("process execution has bounded waiting", processTimeout),
            ("existing settings migrate without enabling new actions", policyMigration),
            ("Intelligence follows phone readiness without repeated changes", policyTransitions),
            ("correct policy selection is a complete no-op", policyNoOp),
            ("unchecked policy action leaves manual selection alone", policyDisabled),
            ("turning either switch off restores Singapore", policySwitchOff),
            ("late SIM selection is compensated after disconnect", policyStaleSelection),
            ("policy fallback survives Surge absence and restart", policyPendingFallback),
            ("policy changes require valid options and readback", policyValidation),
            ("policy cache failures retry only the cache flush", policyFlushFailure),
            ("inactive profiles are cleaned only when active", policyProfiles),
            ("DNS failure still restores the fallback policy", policyModuleFailure),
            ("policy failure cannot prevent module disable", policyFallbackFailure),
            ("disconnect during policy flush restores fallback", policyDisconnectDuringFlush),
            ("profile races retain both possible cleanup targets", policyProfileRace),
        ]
        for (name, test) in tests { try test(); print("PASS: \(name)") }
        print("Surge integration: \(tests.count) tests passed")
    }

    static func noOp() throws {
        let f = try Fixture(); f.surge.enabled = true
        let before = try [f.stamp(f.module), f.stamp(f.profile)]
        let controller = try f.coordinator()
        for _ in 0..<3 {
            let status = try controller.reconcile(settings: f.settings, network: f.phone(), dnsReady: true, stillCurrent: { true })
            try check(status.state == "active", "Active status")
        }
        try check(f.surge.mutations.isEmpty && f.surge.checks == 0, "No reload, validation, toggle or flush")
        try check(try [f.stamp(f.module), f.stamp(f.profile)] == before, "Inode and modification date stay unchanged")
        try check(!FileManager.default.fileExists(atPath: f.backup(f.module).path), "No needless backup")
    }

    static func dnsChange() throws {
        let f = try Fixture(); let profileStamp = try f.stamp(f.profile)
        let c = try f.coordinator(); let phone = f.phone(dns: ["192.168.42.3", "192.168.42.4"])
        _ = try c.reconcile(settings: f.settings, network: phone, dnsReady: true, stillCurrent: { true })
        try check(try f.contents(f.module).contains("server:192.168.42.3,192.168.42.4 // keep\r\n"), "All DNS values and comments")
        try check(try f.contents(f.module).contains("router.local = server:system"), "Other mappings preserved")
        try check(try f.contents(f.backup(f.module)) == f.originalModule, "Exact backup")
        try check(try f.stamp(f.profile) == profileStamp, "Unchanged profile not rewritten")
        try check(f.surge.mutations == ["reload", "enable", "flush"], "Ordered application")
        let modifiedStamp = try f.stamp(f.module)
        f.surge.mutations = []
        _ = try c.reconcile(settings: f.settings, network: phone, dnsReady: true, stillCurrent: { true })
        try check(f.surge.mutations.isEmpty, "Repeated snapshot has no side effects")
        try check(try f.stamp(f.module) == modifiedStamp, "No repeated replacement")
        let mode = try FileManager.default.attributesOfItem(atPath: f.module.path)[.posixPermissions] as? NSNumber
        try check(mode?.intValue == 0o640, "Original permissions preserved")
    }

    static func interfaceChange() throws {
        let f = try Fixture(); f.surge.enabled = true
        let originalStamp = try f.stamp(f.module)
        _ = try f.coordinator().reconcile(settings: f.settings, network: f.phone(interface: "feth95"), dnsReady: true, stillCurrent: { true })
        try check(try f.contents(f.profile) == f.originalProfile.replacingOccurrences(of: "bridge9", with: "feth95"), "Only interface value changes")
        try check(try f.stamp(f.module) == originalStamp, "DNS module stays untouched")
        try check(!FileManager.default.fileExists(atPath: f.backup(f.module).path), "No module backup")
        try check(f.surge.mutations == ["reload", "flush"] && f.surge.checks == 1, "No redundant enable")
    }

    static func enableOnly() throws {
        let f = try Fixture()
        _ = try f.coordinator().reconcile(settings: f.settings, network: f.phone(), dnsReady: true, stillCurrent: { true })
        try check(f.surge.mutations == ["enable", "flush"], "Identical files do not prevent enabling")
    }

    static func disconnect() throws {
        for dnsLost in [false, true] {
            let f = try Fixture(); f.surge.enabled = true
            let c = try f.coordinator()
            let phone: SurgePhoneNetwork? = dnsLost ? f.phone(dns: []) : nil
            _ = try c.reconcile(settings: f.settings, network: phone, dnsReady: false, stillCurrent: { false })
            _ = try c.reconcile(settings: f.settings, network: phone, dnsReady: false, stillCurrent: { false })
            try check(f.surge.mutations == ["disable", "flush"], "Disable and flush exactly once")
            try check(try f.contents(f.module) == f.originalModule, "Never write empty DNS")
        }
    }

    static func pendingDisable() throws {
        let f = try Fixture(); f.surge.enabled = true
        let c = try f.coordinator()
        _ = try c.reconcile(settings: f.settings, network: f.phone(), dnsReady: true, stillCurrent: { true })
        f.settings.enabled = false; f.settings.changed(requestCleanup: true); f.surge.running = false
        try fails { _ = try c.reconcile(settings: f.settings, network: nil, dnsReady: false, stillCurrent: { false }) }
        try check(try f.storage.journal().ownsModule, "Cleanup intent persisted")
        let restarted = try f.coordinator(); f.surge.running = true
        _ = try restarted.reconcile(settings: f.settings, network: nil, dnsReady: false, stillCurrent: { false })
        try check(f.surge.mutations == ["disable", "flush"], "Pending cleanup resumed")
        try check(try !f.storage.journal().ownsModule, "Ownership released after cleanup")
        f.surge.mutations = []; f.surge.enabled = true
        f.settings.profilePath = f.profile.path
        f.settings.changed() // Editing preferences while off must not reclaim module control.
        _ = try restarted.reconcile(settings: f.settings, network: nil, dnsReady: false, stillCurrent: { false })
        try check(f.surge.mutations.isEmpty && f.surge.enabled, "Off no longer overrides manual control")
    }

    static func disableTimeout() throws {
        let f = try Fixture(); f.surge.enabled = true; f.surge.timeoutAfterDisable = true
        let c = try f.coordinator()
        try fails { _ = try c.reconcile(settings: f.settings, network: nil, dnsReady: false, stillCurrent: { false }) }
        try check(try f.storage.journal().needsFlush, "Persist before possibly successful command")
        _ = try f.coordinator().reconcile(settings: f.settings, network: nil, dnsReady: false, stillCurrent: { false })
        try check(f.surge.mutations == ["disable", "flush"], "Readback avoids duplicate disable")
    }

    static func flushFailure() throws {
        let f = try Fixture(); f.surge.flushFailures = 1
        let c = try f.coordinator(); let phone = f.phone(dns: ["192.168.42.7"])
        try fails { _ = try c.reconcile(settings: f.settings, network: phone, dnsReady: true, stillCurrent: { true }) }
        try check(f.surge.enabled && c.journal.needsFlush, "Keep applied configuration with pending flush")
        let stamp = try f.stamp(f.module); f.surge.mutations = []
        _ = try c.reconcile(settings: f.settings, network: phone, dnsReady: true, stillCurrent: { true })
        try check(f.surge.mutations == ["flush"], "Retry only cache invalidation")
        try check(try f.stamp(f.module) == stamp, "No rewritten configuration on cache retry")
    }

    static func rollback() throws {
        let f = try Fixture(); f.surge.enabled = true; f.surge.reloadFails = true
        let c = try f.coordinator()
        try fails { _ = try c.reconcile(settings: f.settings, network: f.phone(interface: "bridge5", dns: ["192.168.42.5"]), dnsReady: true, stillCurrent: { true }) }
        try check(try f.contents(f.module) == f.originalModule && f.contents(f.profile) == f.originalProfile, "Both originals restored")
        try check(!f.surge.enabled && c.journal.needsReload, "Old module disabled; rollback reload remains pending")
        f.surge.reloadFails = false
        _ = try c.reconcile(settings: f.settings, network: nil, dnsReady: false, stillCurrent: { false })
        try check(!c.journal.needsReload && !c.journal.needsFlush, "Rollback applied on recovery")
    }

    static func concurrentEdit() throws {
        let f = try Fixture()
        let userEdit = f.originalProfile + "# concurrent edit\n"
        f.surge.onCheck = { try Data(userEdit.utf8).write(to: f.profile) }
        let c = try f.coordinator()
        try fails { _ = try c.reconcile(settings: f.settings, network: f.phone(interface: "bridge6"), dnsReady: true, stillCurrent: { true }) }
        try check(try f.contents(f.profile) == userEdit, "Do not overwrite other edits")
        try check(!c.journal.needsReload && !f.surge.mutations.contains("reload"), "No reload if no file was written")
        try check(!FileManager.default.fileExists(atPath: f.backup(f.profile).path), "No backup on failed comparison")
    }

    static func disconnectDuringEnable() throws {
        let f = try Fixture(); var connected = true
        f.surge.onEnable = { connected = false }
        try fails { _ = try f.coordinator().reconcile(settings: f.settings, network: f.phone(), dnsReady: true, stillCurrent: { connected }) }
        try check(!f.surge.enabled && f.surge.mutations == ["enable", "disable", "flush"], "Compensate obsolete enable immediately")
    }

    static func cancelledWork() throws {
        let f = try Fixture(); let stamp = try f.stamp(f.module)
        try fails { _ = try f.coordinator().reconcile(settings: f.settings, network: f.phone(dns: ["192.168.42.8"]), dnsReady: true, stillCurrent: { false }) }
        try check(try f.stamp(f.module) == stamp, "Stale work never writes")
        try check(!f.surge.mutations.contains("enable"), "Stale work never enables")
    }

    static func profileSwitch() throws {
        let f = try Fixture()
        f.surge.onCheck = { f.surge.profile = "Other" }
        try fails { _ = try f.coordinator().reconcile(settings: f.settings, network: f.phone(interface: "bridge4"), dnsReady: true, stillCurrent: { true }) }
        try check(try f.contents(f.profile) == f.originalProfile, "Switch cancels edits to old profile")
        try check(!f.surge.enabled, "No enable in a different profile")
    }

    static func invalidConfiguration() throws {
        let f = try Fixture(); f.surge.enabled = true
        try Data((f.originalProfile + "[Proxy]\nSIM = direct\n").utf8).write(to: f.profile)
        try fails { _ = try f.coordinator().reconcile(settings: f.settings, network: f.phone(), dnsReady: true, stillCurrent: { true }) }
        try check(!f.surge.enabled, "Ambiguous policy fails closed")
        try check(!FileManager.default.fileExists(atPath: f.backup(f.profile).path), "Invalid files never overwritten")
    }

    static func enableReadback() throws {
        let f = try Fixture(); f.surge.ignoreEnable = true
        try fails { _ = try f.coordinator().reconcile(settings: f.settings, network: f.phone(), dnsReady: true, stillCurrent: { true }) }
        try check(!f.surge.enabled, "Success cannot be inferred from exit code")
    }

    static func duplicateModules() throws {
        let f = try Fixture(); f.surge.enabled = true
        try Data(f.originalModule.utf8).write(to: f.root.appendingPathComponent("Duplicate.sgmodule"))
        try fails { _ = try f.coordinator().reconcile(settings: f.settings, network: f.phone(dns: ["192.168.42.5"]), dnsReady: true, stillCurrent: { true }) }
        try check(try f.contents(f.module) == f.originalModule, "Duplicate names never update the selected file")
        try check(!f.surge.enabled, "Ambiguous module is disabled")
    }

    static func defaultOff() throws {
        let f = try Fixture(); f.surge.enabled = true
        _ = try f.coordinator().reconcile(settings: SurgeSettings(), network: nil, dnsReady: false, stillCurrent: { false })
        try check(f.surge.enabled && f.surge.queries == 0, "No control before opt-in")
    }

    static func formatting() throws {
        let original = "#!name=SIM DNS\r\n[Host]\r\nx = server:192.168.42.1:53, 192.168.42.2 \t// note\r\n"
        try check(try SurgeConfiguration.module(original, dns: ["192.168.42.1", "192.168.42.2"]) == original, "Semantic equality preserves every byte")
        let profile = "[Proxy]\r\nSIM = direct, INTERFACE=bridge9, dns-follow-interface=true # comment\r\n"
        try check(try SurgeConfiguration.profile(profile, interface: "bridge9") == profile, "Unchanged policy preserves every byte")
        let noInterface = "[Proxy]\r\n  SIM = direct, dns-follow-interface=true  // comment\r\n"
        try check(try SurgeConfiguration.profile(noInterface, interface: "feth97").contains("interface=feth97  // comment\r\n"), "Insert missing binding without removing comment")
    }

    static func scope() throws {
        let f = try Fixture()
        f.settings.profilePath = f.root.appendingPathComponent("Other.conf").path
        try fails { _ = try SurgeConfiguration.profileURL(settings: f.settings, current: "Main") }
        try fails { _ = try SurgeConfiguration.profileURL(settings: f.settings, current: "../Main") }
        try fails { _ = try SurgeConfiguration.profile(f.originalProfile, interface: "bridge9,invalid=true") }
        let link = f.root.appendingPathComponent("link.sgmodule")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.module)
        try fails { try SurgeFileTransaction().prepare(link) { $0 + "x" } }
    }

    static func leaseParsing() throws {
        try check(SurgeNetworkObserver.ipv4Options(Data([192,168,42,1, 8,8,8,8, 192,168,42,1])) == ["192.168.42.1", "8.8.8.8"], "All DHCP DNS addresses, deduplicated in order")
        try check(SurgeNetworkObserver.ipv4Options(Data([1,2,3])).isEmpty, "Reject truncated DHCP options")
        try check(SurgeNetworkObserver.ipv4Options(Data([127,0,0,1,169,254,1,1])).isEmpty, "Reject loopback and link-local values")
        let runtime = SurgeRuntime(state: "connected", hostInterface: "bridge12", connectedSince: 90, updatedAt: 100, processID: 123)
        try check(runtime.connected(at: 105) && !runtime.connected(at: 111) && !runtime.connected(at: 90), "Freshness and clock checks")
        for state in ["paused", "waiting", "connecting", "stopped", "error"] {
            try check(!SurgeRuntime(state: state, hostInterface: "feth97", connectedSince: 90, updatedAt: 100, processID: 123).connected(at: 101), "Only active USB sessions qualify")
        }
    }

    static func dnsReplies() throws {
        let query: [UInt8] = [0x12,0x34,1,0,0,1,0,0,0,0,0,0, 1,120,0,0,1,0,1]
        var reply = query; reply[2] = 0x81; reply[3] = 0x80; reply[7] = 1
        reply += [0xc0,0x0c,0,1,0,1,0,0,0,60,0,4,93,184,215,14]
        try check(SurgeDNSProbe.accepts(reply, query: query), "Complete matched A answer")
        var invalid = reply; invalid[0] = 0
        try check(!SurgeDNSProbe.accepts(invalid, query: query), "Mismatched transaction")
        invalid = reply; invalid[3] = 0x82
        try check(!SurgeDNSProbe.accepts(invalid, query: query), "SERVFAIL is not ready")
        try check(!SurgeDNSProbe.accepts(Array(reply.dropLast()), query: query), "Reject truncated answer")
        invalid = reply; invalid[invalid.count - 4] = 198; invalid[invalid.count - 3] = 18
        try check(!SurgeDNSProbe.accepts(invalid, query: query), "Fake-IP is not a phone DNS answer")
    }

    static func processTimeout() throws {
        let result = try SurgeProcess.run(URL(fileURLWithPath: "/usr/bin/printf"), ["literal output"])
        try check(result.status == 0 && result.output == "literal output", "Capture command output")
        let start = ProcessInfo.processInfo.systemUptime
        try fails { _ = try SurgeProcess.run(URL(fileURLWithPath: "/bin/sleep"), ["5"], timeout: 0.05) }
        try check(ProcessInfo.processInfo.systemUptime - start < 2, "Command timeout is bounded")
    }

    static func policyMigration() throws {
        let old = Data("{\"enabled\":true,\"modulePath\":\"/old/SIM.sgmodule\",\"profilePath\":\"\",\"revision\":\"old\",\"cleanupRevision\":\"\",\"hasBeenEnabled\":true}".utf8)
        let value = try JSONDecoder().decode(SurgeSettings.self, from: old)
        try check(value.enabled && value.hasBeenEnabled && !value.switchIntelligence, "Preserve old preferences; new option defaults off")
        try check(value.modulePath == "/old/SIM.sgmodule", "Keep configured path")
        try check(try JSONDecoder().decode(SurgeSettings.self, from: JSONEncoder().encode(value)) == value, "New settings round trip")
    }

    static func policyTransitions() throws {
        let f = try Fixture(); f.settings.switchIntelligence = true; f.surge.enabled = true
        let before = try [f.stamp(f.module), f.stamp(f.profile)]
        let c = try SurgeLinkCoordinator(controller: f.surge, storage: f.storage)
        let active = try c.reconcile(settings: f.settings, network: f.phone(), dnsReady: true, stillCurrent: { true })
        try check(active.policySelection == "SIM-Route", "Show verified selection")
        try check(f.surge.mutations == ["policy:SIM-Route", "flush"], "Switch without a file edit or reload")
        f.surge.mutations = []
        _ = try c.reconcile(settings: f.settings, network: f.phone(), dnsReady: true, stillCurrent: { true })
        try check(f.surge.mutations.isEmpty, "Unchanged selection needs no command or flush")
        _ = try c.reconcile(settings: f.settings, network: nil, dnsReady: false, stillCurrent: { false })
        try check(f.surge.selections["Main"] == "新加坡节点" && !f.surge.enabled, "Disconnect disables DNS and restores Singapore")
        try check(try [f.stamp(f.module), f.stamp(f.profile)] == before, "Policy changes never rewrite either file")
    }

    static func policyNoOp() throws {
        let f = try Fixture(); f.settings.switchIntelligence = true
        f.surge.selections["Main"] = "SIM-Route"
        let c = try SurgePolicyCoordinator(controller: f.surge, storage: f.storage)
        _ = try c.reconcile(settings: f.settings, phoneReady: true, expectedProfile: "Main", stillCurrent: { true })
        try check(f.surge.mutations.isEmpty && c.journal.profiles == ["Main"], "Claim an already correct selection without mutating Surge")
        _ = try c.reconcile(settings: f.settings, phoneReady: false, expectedProfile: nil, stillCurrent: { false })
        try check(f.surge.mutations == ["policy:新加坡节点", "flush"], "Still restore fallback on disconnect")
    }

    static func policyDisabled() throws {
        let f = try Fixture(); f.surge.selections["Main"] = "Proxy"
        let c = try SurgePolicyCoordinator(controller: f.surge, storage: f.storage)
        _ = try c.reconcile(settings: f.settings, phoneReady: true, expectedProfile: "Main", stillCurrent: { true })
        try check(f.surge.policyQueries == 0 && f.surge.mutations.isEmpty, "Unchecked action does not control Intelligence")
    }

    static func policySwitchOff() throws {
        for master in [false, true] {
            let f = try Fixture(); f.settings.switchIntelligence = true
            let c = try SurgePolicyCoordinator(controller: f.surge, storage: f.storage)
            _ = try c.reconcile(settings: f.settings, phoneReady: true, expectedProfile: "Main", stillCurrent: { true })
            if master { f.settings.enabled = false } else { f.settings.switchIntelligence = false }
            _ = try c.reconcile(settings: f.settings, phoneReady: true, expectedProfile: "Main", stillCurrent: { true })
            try check(f.surge.selections["Main"] == "新加坡节点" && !c.journal.pending, "Off restores fallback and releases control")
            f.surge.mutations = []; f.surge.selections["Main"] = "Proxy"
            _ = try c.reconcile(settings: f.settings, phoneReady: true, expectedProfile: "Main", stillCurrent: { true })
            try check(f.surge.mutations.isEmpty, "Manual selection is respected after cleanup")
        }
    }

    static func policyStaleSelection() throws {
        let f = try Fixture(); f.settings.switchIntelligence = true; var connected = true
        f.surge.onPolicyChange = { policy in if policy == "SIM-Route" { connected = false } }
        let c = try SurgePolicyCoordinator(controller: f.surge, storage: f.storage)
        try fails { _ = try c.reconcile(settings: f.settings, phoneReady: true, expectedProfile: "Main", stillCurrent: { connected }) }
        try check(f.surge.selections["Main"] == "新加坡节点", "Compensate an obsolete phone route")
        try check(!c.journal.pending, "Compensation verified and flushed")
    }

    static func policyPendingFallback() throws {
        let f = try Fixture(); f.settings.switchIntelligence = true
        let c = try SurgePolicyCoordinator(controller: f.surge, storage: f.storage)
        _ = try c.reconcile(settings: f.settings, phoneReady: true, expectedProfile: "Main", stillCurrent: { true })
        f.surge.running = false; f.settings.enabled = false
        try fails { _ = try c.reconcile(settings: f.settings, phoneReady: false, expectedProfile: nil, stillCurrent: { false }) }
        try check(try f.storage.policyJournal().profiles == ["Main"], "Retain pending fallback")
        f.surge.running = true
        let restarted = try SurgePolicyCoordinator(controller: f.surge, storage: f.storage)
        _ = try restarted.reconcile(settings: f.settings, phoneReady: false, expectedProfile: nil, stillCurrent: { false })
        try check(f.surge.selections["Main"] == "新加坡节点" && !restarted.journal.pending, "Restart finishes pending fallback")
    }

    static func policyValidation() throws {
        let f = try Fixture(); f.settings.switchIntelligence = true
        let c = try SurgePolicyCoordinator(controller: f.surge, storage: f.storage)
        f.surge.policyOptions = ["SIM-Route"]
        try fails { _ = try c.reconcile(settings: f.settings, phoneReady: true, expectedProfile: "Main", stillCurrent: { true }) }
        try check(f.surge.mutations.isEmpty, "Do not enter a route without an available fallback")
        f.surge.policyOptions = ["SIM-Route", "新加坡节点"]; f.surge.ignorePolicyChange = true
        try fails { _ = try c.reconcile(settings: f.settings, phoneReady: true, expectedProfile: "Main", stillCurrent: { true }) }
        try check(f.surge.selections["Main"] == "新加坡节点", "Exit success alone cannot prove the selected route")
        f.surge.mutations = []
        try fails { _ = try c.reconcile(settings: f.settings, phoneReady: true, expectedProfile: "Other", stillCurrent: { true }) }
        try check(f.surge.mutations.isEmpty, "Never apply a result to a different active profile")
    }

    static func policyFlushFailure() throws {
        let f = try Fixture(); f.settings.switchIntelligence = true; f.surge.flushFailures = 1
        let c = try SurgePolicyCoordinator(controller: f.surge, storage: f.storage)
        try fails { _ = try c.reconcile(settings: f.settings, phoneReady: true, expectedProfile: "Main", stillCurrent: { true }) }
        try check(f.surge.selections["Main"] == "SIM-Route" && c.journal.needsFlush, "Keep verified policy on a cache error")
        f.surge.mutations = []
        _ = try c.reconcile(settings: f.settings, phoneReady: true, expectedProfile: "Main", stillCurrent: { true })
        try check(f.surge.mutations == ["flush"], "No redundant policy change on flush retry")
    }

    static func policyProfiles() throws {
        let f = try Fixture(); f.settings.switchIntelligence = true
        let c = try SurgeLinkCoordinator(controller: f.surge, storage: f.storage)
        _ = try c.reconcile(settings: f.settings, network: f.phone(), dnsReady: true, stillCurrent: { true })
        f.settings.enabled = false; f.settings.changed(requestCleanup: true); f.surge.profile = "Other"
        let waiting = try c.reconcile(settings: f.settings, network: nil, dnsReady: false, stillCurrent: { false })
        try check(waiting.state == "pendingPolicy" && f.surge.selections["Other"] == "Proxy", "Do not touch an unrelated active profile")
        f.surge.profile = "Main"
        let done = try c.reconcile(settings: f.settings, network: nil, dnsReady: false, stillCurrent: { false })
        try check(done.state == "off" && f.surge.selections["Main"] == "新加坡节点", "Restore the original profile when it becomes active")
    }

    static func policyModuleFailure() throws {
        let f = try Fixture(); f.settings.switchIntelligence = true
        let c = try SurgeLinkCoordinator(controller: f.surge, storage: f.storage)
        _ = try c.reconcile(settings: f.settings, network: f.phone(), dnsReady: true, stillCurrent: { true })
        try Data("invalid module".utf8).write(to: f.module)
        try fails { _ = try c.reconcile(settings: f.settings, network: f.phone(), dnsReady: true, stillCurrent: { true }) }
        try check(!f.surge.enabled && f.surge.selections["Main"] == "新加坡节点", "DNS failure restores a usable fallback")
    }

    static func policyFallbackFailure() throws {
        let f = try Fixture(); f.settings.switchIntelligence = true
        let c = try SurgeLinkCoordinator(controller: f.surge, storage: f.storage)
        _ = try c.reconcile(settings: f.settings, network: f.phone(), dnsReady: true, stillCurrent: { true })
        f.surge.policyFailures = ["新加坡节点"]
        try fails { _ = try c.reconcile(settings: f.settings, network: nil, dnsReady: false, stillCurrent: { false }) }
        try check(!f.surge.enabled && c.policies.journal.pending, "Module shutdown proceeds even while policy cleanup fails")
        f.surge.policyFailures = []
        _ = try c.reconcile(settings: f.settings, network: nil, dnsReady: false, stillCurrent: { false })
        try check(f.surge.selections["Main"] == "新加坡节点", "Failed fallback is retried")
    }

    static func policyDisconnectDuringFlush() throws {
        let f = try Fixture(); f.settings.switchIntelligence = true; var connected = true
        f.surge.onFlush = { connected = false }
        let c = try SurgePolicyCoordinator(controller: f.surge, storage: f.storage)
        try fails { _ = try c.reconcile(settings: f.settings, phoneReady: true, expectedProfile: "Main", stillCurrent: { connected }) }
        try check(f.surge.selections["Main"] == "新加坡节点" && !c.journal.pending, "Do not report active after a late disconnect")
    }

    static func policyProfileRace() throws {
        let f = try Fixture(); f.settings.switchIntelligence = true
        f.surge.onPolicyChange = { policy in
            if policy == "SIM-Route" { f.surge.profile = "Other"; f.surge.selections["Other"] = policy }
        }
        let c = try SurgePolicyCoordinator(controller: f.surge, storage: f.storage)
        try fails { _ = try c.reconcile(settings: f.settings, phoneReady: true, expectedProfile: "Main", stillCurrent: { true }) }
        try check(f.surge.selections["Other"] == "新加坡节点" && c.journal.profiles == ["Main"], "Compensate the active recipient and retain inactive cleanup")
        f.surge.profile = "Main"; f.settings.enabled = false
        _ = try c.reconcile(settings: f.settings, phoneReady: false, expectedProfile: nil, stillCurrent: { false })
        try check(f.surge.selections["Main"] == "新加坡节点" && !c.journal.pending, "Finish original-profile cleanup when it is active")
    }
}
