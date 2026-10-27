// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin

enum SurgeIntegrationError: LocalizedError {
    case configuration(String)
    case command(String)
    case unavailable
    case superseded

    var errorDescription: String? {
        switch self {
        case .configuration(let message), .command(let message): return message
        case .unavailable: return "Waiting for Surge. The operation will be retried automatically."
        case .superseded: return "The connection or settings changed; checking again."
        }
    }
}

struct SurgeSettings: Codable, Equatable {
    var enabled = false
    var switchIntelligence = false
    var autoStartUSB = false
    var adbPath = ""
    var adbRetryToken = ""
    var adbPausedProcessID: Int32?
    var modulePath = ""
    // Empty means the active profile in the selected module's directory.
    var profilePath = ""
    var revision = ""
    var cleanupRevision = ""
    var hasBeenEnabled = false

    mutating func changed(requestCleanup: Bool = false) {
        revision = UUID().uuidString
        hasBeenEnabled = hasBeenEnabled || enabled
        if requestCleanup { cleanupRevision = revision }
    }
}

extension SurgeSettings {
    // Preserve existing installations: a newly added action starts unchecked.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        switchIntelligence = try values.decodeIfPresent(Bool.self, forKey: .switchIntelligence) ?? false
        autoStartUSB = try values.decodeIfPresent(Bool.self, forKey: .autoStartUSB) ?? false
        adbPath = try values.decodeIfPresent(String.self, forKey: .adbPath) ?? ""
        adbRetryToken = try values.decodeIfPresent(String.self, forKey: .adbRetryToken) ?? ""
        adbPausedProcessID = try values.decodeIfPresent(Int32.self, forKey: .adbPausedProcessID)
        modulePath = try values.decodeIfPresent(String.self, forKey: .modulePath) ?? ""
        profilePath = try values.decodeIfPresent(String.self, forKey: .profilePath) ?? ""
        revision = try values.decodeIfPresent(String.self, forKey: .revision) ?? ""
        cleanupRevision = try values.decodeIfPresent(String.self, forKey: .cleanupRevision) ?? ""
        hasBeenEnabled = try values.decodeIfPresent(Bool.self, forKey: .hasBeenEnabled) ?? false
    }
}

struct SurgePhoneNetwork: Codable, Equatable {
    let interface: String
    let address: String
    let dnsServers: [String]
    let gateway: String
    let session: String
}

struct SurgeJournal: Codable, Equatable {
    var ownsModule = false
    var cleanedRevision: String?
    var needsReload = false
    var needsFlush = false
    var lastNetwork: SurgePhoneNetwork?
}

struct SurgeLinkStatus: Codable, Equatable {
    var state: String
    var detail: String = ""
    var network: SurgePhoneNetwork?
    var updatedAt = Date().timeIntervalSince1970
    var activeProfile: String?
    var policySelection: String?
}

struct SurgeStorage {
    let directory: URL
    static var standard: SurgeStorage {
        SurgeStorage(directory: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/HoRNDIS/Surge", isDirectory: true))
    }
    var settingsURL: URL { directory.appendingPathComponent("settings.json", isDirectory: false) }
    var journalURL: URL { directory.appendingPathComponent("journal.json", isDirectory: false) }
    var statusURL: URL { directory.appendingPathComponent("status.json", isDirectory: false) }
    var policyJournalURL: URL { directory.appendingPathComponent("policy-journal.json", isDirectory: false) }
    var adbStatusURL: URL { directory.appendingPathComponent("adb-status.json", isDirectory: false) }

    func read<T: Decodable>(_ type: T.Type, from url: URL, default fallback: T) throws -> T {
        guard FileManager.default.fileExists(atPath: url.path) else { return fallback }
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }
    func settings() throws -> SurgeSettings {
        try read(SurgeSettings.self, from: settingsURL, default: SurgeSettings())
    }
    func journal() throws -> SurgeJournal {
        try read(SurgeJournal.self, from: journalURL, default: SurgeJournal())
    }
    func policyJournal() throws -> SurgePolicyJournal {
        try read(SurgePolicyJournal.self, from: policyJournalURL, default: SurgePolicyJournal())
    }
    func save<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        if (try? Data(contentsOf: url)) == data { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

struct SurgeModules: Decodable {
    let enabled: [String]
    let available: [String]
}

protocol SurgeControlling {
    func modules() throws -> SurgeModules
    func currentProfile() throws -> String
    func checkProfile(_ path: String) throws
    func reload() throws
    func setModuleEnabled(_ enabled: Bool) throws
    func flushDNS() throws
    func intelligenceGroup() throws -> SurgePolicyGroup
    func selectIntelligence(_ policy: String) throws
}

enum SurgeConfiguration {
    static let moduleName = "SIM DNS"

    static func validIPv4(_ string: String) -> Bool {
        var address = in_addr()
        guard inet_pton(AF_INET, string, &address) == 1 else { return false }
        let value = UInt32(bigEndian: address.s_addr)
        let first = value >> 24
        return first != 0 && first != 127 && first < 224 &&
            value & 0xffff0000 != 0xa9fe0000 && value != 0xffffffff
    }

    static func validInterface(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count < Int(IFNAMSIZ) &&
            name.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }
    }

    // Edit only numeric, port-53 server mappings in the dedicated [Host] module.
    // Splitting on LF preserves CRLF, trailing newlines, comments and untouched bytes.
    static func module(_ original: String, dns: [String]) throws -> String {
        guard !dns.isEmpty, dns.allSatisfy(validIPv4) else {
            throw SurgeIntegrationError.configuration("The phone did not supply valid DHCP DNS addresses.")
        }
        var lines = original.components(separatedBy: "\n")
        let names = lines.compactMap { line -> String? in
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.hasPrefix("#!name=") else { return nil }
            return String(text.dropFirst(7)).trimmingCharacters(in: .whitespaces)
        }
        guard names == [moduleName] else {
            throw SurgeIntegrationError.configuration("Select a module with exactly one #!name=SIM DNS header.")
        }
        let expression = try NSRegularExpression(pattern: "(?i)^(.*?=\\s*server:)([0-9.,: \\t]+?)([ \\t]*(?://|#).*)?(\\r?)$")
        var section = ""
        var mappings = 0
        for index in lines.indices {
            let trimmed = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
                section = trimmed.lowercased()
                continue
            }
            guard section == "[host]", !trimmed.hasPrefix("#"), !trimmed.hasPrefix("//") else { continue }
            let line = lines[index] as NSString
            guard let match = expression.firstMatch(in: lines[index], range: NSRange(location: 0, length: line.length)) else { continue }
            let oldValue = line.substring(with: match.range(at: 2))
            let values = oldValue.components(separatedBy: ",").map { token -> String in
                let value = token.trimmingCharacters(in: .whitespaces)
                return value.hasSuffix(":53") ? String(value.dropLast(3)) : value
            }
            guard values.allSatisfy(validIPv4) else {
                throw SurgeIntegrationError.configuration("SIM DNS contains an unsupported DNS address or port.")
            }
            mappings += 1
            // Semantic equality must not rewrite whitespace, :53, comments or metadata.
            if values == dns { continue }
            let trailing = String(oldValue.reversed().prefix(while: { $0 == " " || $0 == "\t" }).reversed())
            lines[index] = line.replacingCharacters(in: match.range(at: 2), with: dns.joined(separator: ",") + trailing)
        }
        guard mappings > 0 else {
            throw SurgeIntegrationError.configuration("SIM DNS has no numeric server: mappings in [Host].")
        }
        return lines.joined(separator: "\n")
    }

    static func profile(_ original: String, interface: String) throws -> String {
        guard validInterface(interface) else {
            throw SurgeIntegrationError.configuration("The phone interface name is invalid.")
        }
        var lines = original.components(separatedBy: "\n")
        var section = ""
        var matches = [Int]()
        for index in lines.indices {
            let text = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            if text.hasPrefix("["), text.hasSuffix("]") { section = text.lowercased(); continue }
            if section == "[proxy]", let equals = text.firstIndex(of: "="),
               text[..<equals].trimmingCharacters(in: .whitespaces) == "SIM" { matches.append(index) }
        }
        guard matches.count == 1 else {
            throw SurgeIntegrationError.configuration("The active local profile must contain exactly one SIM policy in [Proxy].")
        }
        let index = matches[0]
        let originalLine = lines[index]
        let comment = originalLine.range(of: "[ \\t]+(?://|#)", options: .regularExpression)?.lowerBound ?? originalLine.endIndex
        let body = String(originalLine[..<comment])
        let suffix = String(originalLine[comment...])
        guard body.range(of: "^\\s*SIM\\s*=\\s*direct\\s*(?:,|$)", options: [.regularExpression, .caseInsensitive]) != nil else {
            throw SurgeIntegrationError.configuration("The SIM policy must be a direct policy.")
        }
        let expression = try NSRegularExpression(pattern: "(?i)(?:,\\s*)interface\\s*=\\s*([^,\\s]+)")
        let nsBody = body as NSString
        let values = expression.matches(in: body, range: NSRange(location: 0, length: nsBody.length))
        guard values.count <= 1 else {
            throw SurgeIntegrationError.configuration("The SIM policy contains duplicate interface parameters.")
        }
        if let match = values.first {
            if nsBody.substring(with: match.range(at: 1)) == interface { return original }
            lines[index] = nsBody.replacingCharacters(in: match.range(at: 1), with: interface) + suffix
        } else {
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            let tail = String(body.reversed().prefix(while: { $0.isWhitespace }).reversed())
            let leading = String(body.prefix(while: { $0.isWhitespace }))
            lines[index] = leading + trimmed + ", interface=" + interface + tail + suffix
        }
        return lines.joined(separator: "\n")
    }

    static func profileURL(settings: SurgeSettings, current: String) throws -> URL {
        guard !current.isEmpty, !current.contains("/"), current != ".", current != ".." else {
            throw SurgeIntegrationError.configuration("Surge returned an invalid active profile name.")
        }
        let filename = current.hasSuffix(".conf") ? current : current + ".conf"
        let moduleURL = URL(fileURLWithPath: settings.modulePath, isDirectory: false).standardizedFileURL
        let profileURL = settings.profilePath.isEmpty
            ? moduleURL.deletingLastPathComponent().appendingPathComponent(filename, isDirectory: false)
            : URL(fileURLWithPath: settings.profilePath, isDirectory: false).standardizedFileURL
        guard profileURL.lastPathComponent == filename,
              profileURL.deletingLastPathComponent() == moduleURL.deletingLastPathComponent() else {
            throw SurgeIntegrationError.configuration("Select SIM DNS in the active profile directory and select the active local .conf file.")
        }
        return profileURL
    }

    static func validateModuleIdentity(_ url: URL) throws {
        let candidates = try FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(),
            includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]).filter { $0.pathExtension == "sgmodule" }
        var matches = [URL]()
        for candidate in candidates {
            let handle = try FileHandle(forReadingFrom: candidate)
            defer { try? handle.close() }
            let prefix = try handle.read(upToCount: 64 * 1024) ?? Data()
            let lines = String(decoding: prefix, as: UTF8.self).components(separatedBy: "\n")
            if lines.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "#!name=\(moduleName)" }) {
                matches.append(candidate.standardizedFileURL)
            }
        }
        guard matches == [url.standardizedFileURL] else {
            throw SurgeIntegrationError.configuration("The selected file must be the only local module named SIM DNS in the active profile directory.")
        }
    }
}

final class SurgeFileTransaction {
    struct Change {
        let url: URL
        let before: Data
        let after: Data
        let permissions: NSNumber
    }
    private(set) var changes = [Change]()
    private var written = [Change]()
    var didWrite: Bool { !written.isEmpty }

    func prepare(_ url: URL, transform: (String) throws -> String) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw SurgeIntegrationError.configuration("The selected configuration must be a regular file, not a symbolic link.")
        }
        guard let size = attributes[.size] as? NSNumber, size.intValue <= 8 * 1024 * 1024 else {
            throw SurgeIntegrationError.configuration("The selected configuration must be smaller than 8 MiB.")
        }
        let data = try Data(contentsOf: url)
        guard data.count <= 8 * 1024 * 1024, let original = String(data: data, encoding: .utf8) else {
            throw SurgeIntegrationError.configuration("The selected configuration must be UTF-8 and smaller than 8 MiB.")
        }
        let updated = Data(try transform(original).utf8)
        if updated != data {
            changes.append(Change(url: url, before: data, after: updated,
                                  permissions: attributes[.posixPermissions] as? NSNumber ?? 0o600))
        }
    }

    func validateProfile(_ url: URL, using controller: SurgeControlling) throws {
        guard let change = changes.first(where: { $0.url == url }) else { return }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".horndis-check-\(UUID().uuidString).conf", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Self.write(change.after, to: temporary, permissions: 0o600)
        try controller.checkProfile(temporary.path)
    }

    func commit() throws {
        // Check both files before writing either; recheck each just before replacement.
        for change in changes { try ensureUnchanged(change) }
        for change in changes {
            try ensureUnchanged(change)
            try Self.write(change.before, to: URL(fileURLWithPath: change.url.path + ".horndis-backup", isDirectory: false),
                           permissions: change.permissions)
            try ensureUnchanged(change)
            try Self.write(change.after, to: change.url, permissions: change.permissions)
            written.append(change)
        }
    }

    func rollback() throws {
        for change in written.reversed() {
            guard try Data(contentsOf: change.url) == change.after else {
                throw SurgeIntegrationError.configuration("A configuration was edited concurrently; automatic rollback was stopped.")
            }
            try Self.write(change.before, to: change.url, permissions: change.permissions)
        }
    }

    private func ensureUnchanged(_ change: Change) throws {
        guard try Data(contentsOf: change.url) == change.before else {
            throw SurgeIntegrationError.configuration("The configuration changed while being read. Retrying without overwriting the other edit.")
        }
    }

    private static func write(_ data: Data, to url: URL, permissions: NSNumber) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".horndis-write-\(UUID().uuidString)", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard FileManager.default.createFile(atPath: temporary.path, contents: data,
                                             attributes: [.posixPermissions: permissions]) else {
            throw SurgeIntegrationError.configuration("Cannot write \(url.lastPathComponent). Check its directory permissions.")
        }
        guard rename(temporary.path, url.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

final class SurgeCoordinator {
    let controller: SurgeControlling
    let storage: SurgeStorage
    private(set) var journal: SurgeJournal

    init(controller: SurgeControlling, storage: SurgeStorage) throws {
        self.controller = controller
        self.storage = storage
        journal = try storage.journal()
    }

    private func save() throws { try storage.save(journal, to: storage.journalURL) }

    // Record intent BEFORE commands: a timeout may mean the command succeeded.
    private func disable() throws {
        let modules = try controller.modules()
        if modules.enabled.contains(SurgeConfiguration.moduleName) {
            journal.needsFlush = true
            try save()
            try controller.setModuleEnabled(false)
            guard !(try controller.modules()).enabled.contains(SurgeConfiguration.moduleName) else {
                throw SurgeIntegrationError.command("Surge did not disable SIM DNS.")
            }
        }
        if journal.needsFlush {
            try controller.flushDNS()
            journal.needsFlush = false
            try save()
        }
    }

    func reconcile(settings: SurgeSettings, network: SurgePhoneNetwork?, dnsReady: Bool,
                   stillCurrent: () -> Bool) throws -> SurgeLinkStatus {
        if settings.hasBeenEnabled && (settings.enabled ||
            (!settings.cleanupRevision.isEmpty && journal.cleanedRevision != settings.cleanupRevision)) {
            journal.ownsModule = true
            try save()
        }
        guard journal.ownsModule || journal.needsFlush || journal.needsReload else {
            return SurgeLinkStatus(state: "off")
        }
        guard settings.enabled, let network, dnsReady else {
            try disable()
            if journal.needsReload {
                try controller.reload()
                journal.needsReload = false
                journal.needsFlush = true
                try save()
                try disable()
            }
            journal.lastNetwork = nil
            if !settings.enabled {
                journal.ownsModule = false
                journal.cleanedRevision = settings.cleanupRevision
            }
            try save()
            return SurgeLinkStatus(state: settings.enabled ? (network == nil ? "waitingUSB" : "waitingDNS") : "off", network: network)
        }

        let transaction = SurgeFileTransaction()
        let previousReload = journal.needsReload
        var applied = false
        do {
            let modules = try controller.modules()
            guard modules.available.filter({ $0 == SurgeConfiguration.moduleName }).count == 1 else {
                throw SurgeIntegrationError.configuration("Surge must list exactly one available SIM DNS module. Check the module path and duplicate names.")
            }
            guard settings.modulePath.hasPrefix("/"), settings.modulePath.hasSuffix(".sgmodule") else {
                throw SurgeIntegrationError.configuration("Choose the local SIM DNS .sgmodule file first.")
            }
            let profileName = try controller.currentProfile()
            let profile = try SurgeConfiguration.profileURL(settings: settings, current: profileName)
            let module = URL(fileURLWithPath: settings.modulePath, isDirectory: false).standardizedFileURL
            try SurgeConfiguration.validateModuleIdentity(module)
            try transaction.prepare(module) { try SurgeConfiguration.module($0, dns: network.dnsServers) }
            try transaction.prepare(profile) { try SurgeConfiguration.profile($0, interface: network.interface) }
            try transaction.validateProfile(profile, using: controller)
            guard stillCurrent(), try controller.currentProfile() == profileName else { throw SurgeIntegrationError.superseded }
            if !transaction.changes.isEmpty {
                journal.needsReload = true
                try save()
                try transaction.commit()
                journal.needsFlush = true
                try save()
            }
            if journal.needsReload {
                guard stillCurrent() else { throw SurgeIntegrationError.superseded }
                try controller.reload()
                journal.needsReload = false
                journal.needsFlush = true
                try save()
            }
            guard stillCurrent(), try controller.currentProfile() == profileName else { throw SurgeIntegrationError.superseded }
            if !(try controller.modules()).enabled.contains(SurgeConfiguration.moduleName) {
                journal.needsFlush = true
                try save()
                try controller.setModuleEnabled(true)
            }
            guard stillCurrent() else { throw SurgeIntegrationError.superseded }
            guard (try controller.modules()).enabled.contains(SurgeConfiguration.moduleName) else {
                throw SurgeIntegrationError.command("Surge did not enable SIM DNS.")
            }
            applied = true
            if journal.needsFlush {
                try controller.flushDNS()
                journal.needsFlush = false
            }
            guard stillCurrent(), try controller.currentProfile() == profileName else { throw SurgeIntegrationError.superseded }
            journal.lastNetwork = network
            try save()
            return SurgeLinkStatus(state: "active", network: network, activeProfile: profileName)
        } catch {
            let originalError = error
            // A cache failure does not invalidate successfully applied configuration.
            // Keep the pending flag and retry only the flush on the next reconciliation.
            if case SurgeIntegrationError.superseded = originalError {
                // Even an already-applied command must be compensated if its session ended.
            } else if applied && stillCurrent() { try save(); throw originalError }
            if transaction.didWrite {
                journal.needsReload = true
                journal.needsFlush = true
                try save()
                do { try transaction.rollback() }
                catch {
                    try? disable()
                    throw SurgeIntegrationError.configuration("\(originalError.localizedDescription) Rollback: \(error.localizedDescription)")
                }
            } else {
                journal.needsReload = previousReload
            }
            try save()
            do { try disable() }
            catch {
                if case SurgeIntegrationError.unavailable = originalError { throw originalError }
                throw SurgeIntegrationError.command("\(originalError.localizedDescription) Pending disable: \(error.localizedDescription)")
            }
            throw originalError
        }
    }
}
