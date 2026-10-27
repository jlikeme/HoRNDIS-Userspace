// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

struct SurgePolicyGroup: Decodable {
    struct Option: Decodable {
        let name: String
        let enabled: Bool
    }
    let name: String
    let selected: String
    let options: [Option]

    func contains(_ policy: String) -> Bool {
        options.contains { $0.name == policy && $0.enabled }
    }
}

struct SurgePolicyJournal: Codable, Equatable {
    // Surge remembers selections per profile. Never activate an inactive profile
    // to clean it up; retain the intent until the user returns to that profile.
    var profiles = [String]()
    var needsFlush = false
    var pending: Bool { !profiles.isEmpty || needsFlush }
}

struct SurgePolicyResult {
    var selection: String?
    var pendingProfiles = [String]()
}

final class SurgePolicyCoordinator {
    static let group = "Intelligence"
    static let phone = "SIM-Route"
    static let fallback = "新加坡节点"
    let controller: SurgeControlling
    let storage: SurgeStorage
    private(set) var journal: SurgePolicyJournal

    init(controller: SurgeControlling, storage: SurgeStorage) throws {
        self.controller = controller
        self.storage = storage
        journal = try storage.policyJournal()
    }

    private func save() throws { try storage.save(journal, to: storage.policyJournalURL) }

    private func remember(_ profile: String) throws {
        if !journal.profiles.contains(profile) { journal.profiles.append(profile) }
        try save()
    }

    private func flush() throws {
        if journal.needsFlush {
            try controller.flushDNS()
            journal.needsFlush = false
            try save()
        }
    }

    private func select(_ policy: String, profile: String, stillCurrent: () -> Bool) throws {
        let group = try controller.intelligenceGroup()
        guard group.name == Self.group, group.contains(policy),
              policy != Self.phone || group.contains(Self.fallback) else {
            throw SurgeIntegrationError.configuration("Intelligence must contain enabled SIM-Route and 新加坡节点 options.")
        }
        guard try controller.currentProfile() == profile,
              policy != Self.phone || stillCurrent() else { throw SurgeIntegrationError.superseded }
        if policy == Self.fallback && group.selected == policy {
            if journal.profiles.contains(profile) {
                journal.profiles.removeAll { $0 == profile }
                try save()
            }
            return
        }
        // A timeout can mean the selection already changed. Persist before issuing it.
        // Claim an already-selected SIM-Route too: disconnect must still restore fallback.
        try remember(profile)
        if group.selected != policy {
            journal.needsFlush = true
            try save()
            try controller.selectIntelligence(policy)
        }
        let current = try controller.currentProfile()
        guard current == profile else {
            // A profile switch can race the command. Reconcile both possible recipients.
            if policy == Self.phone { try remember(current) }
            throw SurgeIntegrationError.superseded
        }
        guard policy != Self.phone || stillCurrent() else { throw SurgeIntegrationError.superseded }
        let actual = try controller.intelligenceGroup()
        guard actual.name == Self.group, actual.selected == policy else {
            throw SurgeIntegrationError.command("Surge did not select \(policy) for Intelligence.")
        }
        if policy == Self.fallback {
            journal.profiles.removeAll { $0 == profile }
            try save()
        }
    }

    func reconcile(settings: SurgeSettings, phoneReady: Bool, expectedProfile: String?,
                   stillCurrent: () -> Bool) throws -> SurgePolicyResult {
        let enabled = settings.enabled && settings.switchIntelligence
        guard enabled || journal.pending else { return SurgePolicyResult() }
        let profile = try controller.currentProfile()
        let wantsPhone = enabled && phoneReady
        if wantsPhone && expectedProfile != profile { throw SurgeIntegrationError.superseded }
        let shouldSelect = enabled || journal.profiles.contains(profile)
        var selection: String?
        if shouldSelect {
            let desired = wantsPhone ? Self.phone : Self.fallback
            do {
                try select(desired, profile: profile, stillCurrent: stillCurrent)
                selection = desired
            } catch {
                let originalError = error
                // Do not leave a late or ambiguous SIM selection active after failure.
                if wantsPhone {
                    do {
                        let current = try controller.currentProfile()
                        if journal.profiles.contains(current) {
                            try select(Self.fallback, profile: current, stillCurrent: { false })
                            try flush()
                        }
                    } catch {
                        if case SurgeIntegrationError.unavailable = originalError { throw originalError }
                        throw SurgeIntegrationError.command("\(originalError.localizedDescription) Intelligence fallback pending: \(error.localizedDescription)")
                    }
                }
                throw originalError
            }
        }
        // Cache failure retries the flush without undoing a verified selection.
        try flush()
        if wantsPhone {
            let current = try controller.currentProfile()
            if !stillCurrent() || current != profile {
                var cleanup = settings
                cleanup.enabled = false
                _ = try reconcile(settings: cleanup, phoneReady: false, expectedProfile: nil, stillCurrent: { false })
                throw SurgeIntegrationError.superseded
            }
        }
        return SurgePolicyResult(selection: selection, pendingProfiles: wantsPhone ? [] : journal.profiles)
    }
}

// Both actions get a cleanup attempt even if the other action fails. In particular,
// a missing policy group cannot keep SIM DNS enabled after a USB disconnect.
final class SurgeLinkCoordinator {
    let modules: SurgeCoordinator
    let policies: SurgePolicyCoordinator
    var journal: SurgeJournal { modules.journal }

    init(controller: SurgeControlling, storage: SurgeStorage) throws {
        modules = try SurgeCoordinator(controller: controller, storage: storage)
        policies = try SurgePolicyCoordinator(controller: controller, storage: storage)
    }

    func reconcile(settings: SurgeSettings, network: SurgePhoneNetwork?, dnsReady: Bool,
                   stillCurrent: () -> Bool) throws -> SurgeLinkStatus {
        var moduleStatus: SurgeLinkStatus?
        var moduleError: Error?
        do {
            moduleStatus = try modules.reconcile(settings: settings, network: network,
                                                dnsReady: dnsReady, stillCurrent: stillCurrent)
        } catch { moduleError = error }

        var policyResult: SurgePolicyResult?
        var policyError: Error?
        do {
            policyResult = try policies.reconcile(settings: settings,
                phoneReady: moduleStatus?.state == "active", expectedProfile: moduleStatus?.activeProfile,
                stillCurrent: stillCurrent)
        } catch { policyError = error }
        if let moduleError {
            if case SurgeIntegrationError.unavailable = moduleError { throw moduleError }
            if let policyError {
                throw SurgeIntegrationError.command("\(moduleError.localizedDescription) Intelligence: \(policyError.localizedDescription)")
            }
            throw moduleError
        }
        if let policyError { throw policyError }
        var result = moduleStatus ?? SurgeLinkStatus(state: "off")
        result.policySelection = policyResult?.selection
        if let pending = policyResult?.pendingProfiles, !pending.isEmpty {
            result.state = "pendingPolicy"
            result.detail = "Intelligence fallback will be restored when these profiles are active: " + pending.joined(separator: ", ")
        }
        return result
    }
}
