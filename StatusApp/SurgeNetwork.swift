// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin
import SystemConfiguration

struct SurgeRuntime: Decodable {
    let state: String
    let hostInterface: String
    let connectedSince: UInt64
    let updatedAt: UInt64
    let processID: Int32
    var controlAvailable: Bool? = nil
    enum CodingKeys: String, CodingKey {
        case state
        case hostInterface = "host_interface"
        case connectedSince = "connected_since"
        case updatedAt = "updated_at"
        case processID = "process_id"
        case controlAvailable = "control_available"
    }
    func connected(at now: TimeInterval) -> Bool {
        let age = now - Double(updatedAt)
        return state == "connected" && connectedSince > 0 && age >= -2 && age <= 10 &&
            processID > 0 && SurgeConfiguration.validInterface(hostInterface)
    }
}

final class SurgeNetworkObserver {
    private let store: SCDynamicStore
    private var source: CFRunLoopSource?
    private(set) var revision: UInt64 = 0

    init() throws {
        guard let store = SCDynamicStoreCreate(nil, "HoRNDIS Surge" as CFString, nil, nil) else {
            throw SurgeIntegrationError.configuration("Cannot read macOS network configuration.")
        }
        self.store = store
    }

    // The observer is kept alive by the worker for the duration of its run loop.
    func watch() {
        var context = SCDynamicStoreContext(version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        guard let watched = SCDynamicStoreCreate(nil, "HoRNDIS Surge notifications" as CFString,
            { _, _, info in
                guard let info else { return }
                Unmanaged<SurgeNetworkObserver>.fromOpaque(info).takeUnretainedValue().revision &+= 1
            }, &context) else { return }
        let patterns = ["State:/Network/Service/.*/IPv4", "State:/Network/Service/.*/DHCP",
                        "State:/Network/Service/.*/DNS", "State:/Network/Interface/.*/Link"]
        guard SCDynamicStoreSetNotificationKeys(watched, nil, patterns as CFArray),
              let source = SCDynamicStoreCreateRunLoopSource(nil, watched, 0) else { return }
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .defaultMode)
    }

    deinit {
        if let source { CFRunLoopSourceInvalidate(source) }
    }

    static func ipv4Options(_ data: Data?) -> [String] {
        guard let data, !data.isEmpty, data.count % 4 == 0 else { return [] }
        let bytes = [UInt8](data)
        var addresses = [String]()
        for start in stride(from: 0, to: bytes.count, by: 4) {
            let address = bytes[start..<start + 4].map(String.init).joined(separator: ".")
            guard SurgeConfiguration.validIPv4(address) else { continue }
            if !addresses.contains(address) { addresses.append(address) }
        }
        return addresses
    }

    private func dictionary(_ key: String) -> [String: Any]? {
        SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any]
    }

    func snapshot(runtimePath: String = "/var/run/horndis/status.json") throws -> SurgePhoneNetwork? {
        guard let data = FileManager.default.contents(atPath: runtimePath),
              let runtime = try? JSONDecoder().decode(SurgeRuntime.self, from: data),
              runtime.connected(at: Date().timeIntervalSince1970) else { return nil }
        // A stale file must not keep the module enabled after the data agent dies.
        if kill(runtime.processID, 0) != 0 && errno == ESRCH { return nil }
        let interface = runtime.hostInterface
        guard if_nametoindex(interface) != 0 else { return nil }
        if let active = dictionary("State:/Network/Interface/\(interface)/Link")?["Active"] as? Bool,
           !active { return nil }
        let keys = SCDynamicStoreCopyKeyList(store, "State:/Network/Service/[^/]+/IPv4" as CFString) as? [String] ?? []
        var candidates = [(String, [String: Any])]()
        for key in keys {
            guard let state = dictionary(key) else { continue }
            let service = String(key.dropFirst("State:/Network/Service/".count).dropLast("/IPv4".count))
            let device = state["InterfaceName"] as? String ??
                dictionary("Setup:/Network/Service/\(service)/Interface")?["DeviceName"] as? String
            if device == interface { candidates.append((service, state)) }
        }
        var leases = [SurgePhoneNetwork]()
        for (service, state) in candidates {
            guard let dhcp = SCDynamicStoreCopyDHCPInfo(store, service as CFString),
                  let addresses = state["Addresses"] as? [String],
                  let address = addresses.first(where: SurgeConfiguration.validIPv4),
                  Self.interface(interface, hasAddress: address) else { continue }
            if let expiration = DHCPInfoGetLeaseExpirationTime(dhcp),
               CFDateGetAbsoluteTime(expiration) <= CFAbsoluteTimeGetCurrent() { continue }
            let dns = Self.ipv4Options(DHCPInfoGetOptionData(dhcp, 6).map { $0 as Data })
            let routers = Self.ipv4Options(DHCPInfoGetOptionData(dhcp, 3).map { $0 as Data })
            // Preserve an incomplete network in the UI as "waiting for DNS".
            leases.append(SurgePhoneNetwork(interface: interface, address: address,
                dnsServers: dns, gateway: routers.first ?? "",
                session: "\(runtime.processID):\(runtime.connectedSince)"))
        }
        // Do not silently choose a different network or an ambiguous DHCP service.
        if leases.count == 1 { return leases[0] }
        if leases.count > 1 {
            throw SurgeIntegrationError.configuration("Multiple DHCP services match the phone interface.")
        }
        return SurgePhoneNetwork(interface: interface, address: "", dnsServers: [], gateway: "",
                                 session: "\(runtime.processID):\(runtime.connectedSince)")
    }

    private static func interface(_ name: String, hasAddress expected: String) -> Bool {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0 else { return false }
        defer { freeifaddrs(pointer) }
        var current = pointer
        while let item = current {
            defer { current = item.pointee.ifa_next }
            guard String(cString: item.pointee.ifa_name) == name,
                  item.pointee.ifa_flags & UInt32(IFF_UP) != 0,
                  let address = item.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer,
                           socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0,
               String(cString: buffer) == expected { return true }
        }
        return false
    }
}

enum SurgeDNSProbe {
    struct Result {
        let ready: Bool
        let detail: String
        var localNetworkDenied = false
    }

    static func openSocket() -> Int32 {
        let descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else { return descriptor }
        var suppress: Int32 = 1
        guard setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &suppress,
                         socklen_t(MemoryLayout.size(ofValue: suppress))) == 0 else {
            let code = errno
            close(descriptor); errno = code
            return -1
        }
        return descriptor
    }
    // A small direct query bypasses the system resolver and its cached answers.
    // Binding the socket to the detected phone interface also prevents Wi-Fi fallback.
    static func ready(_ network: SurgePhoneNetwork) -> Bool {
        check(network).ready
    }

    static func check(_ network: SurgePhoneNetwork) -> Result {
        guard SurgeConfiguration.validIPv4(network.address),
              SurgeConfiguration.validIPv4(network.gateway), !network.dnsServers.isEmpty else {
            return Result(ready: false, detail: "DHCP address, gateway or DNS is not ready")
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        var failures = [String]()
        var permissionDenied = false
        for server in network.dnsServers {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            if remaining <= 0 { break }
            let result = query(server: server, interface: network.interface, timeout: min(0.8, remaining))
            if result.ready { return result }
            failures.append("\(server): \(result.detail)")
            permissionDenied = permissionDenied || result.localNetworkDenied
        }
        return Result(ready: false, detail: "Phone DNS probe: " + failures.joined(separator: "; "), localNetworkDenied: permissionDenied)
    }

    static func accepts(_ reply: [UInt8], query: [UInt8]) -> Bool {
        guard reply.count >= query.count, query.count >= 12,
              reply[0] == query[0], reply[1] == query[1],
              reply[2] & 0x80 != 0, reply[2] & 0x7a == 0,
              reply[3] & 0x0f == 0, reply[4] == 0, reply[5] == 1,
              reply[6] != 0 || reply[7] != 0,
              Array(reply[12..<query.count]) == Array(query[12...]) else { return false }
        func word(_ offset: Int) -> Int { Int(reply[offset]) << 8 | Int(reply[offset + 1]) }
        var offset = query.count
        var found = false
        for _ in 0..<word(6) {
            var nameFinished = false
            while offset < reply.count {
                let length = Int(reply[offset]); offset += 1
                if length == 0 { nameFinished = true; break }
                if length & 0xc0 == 0xc0 {
                    guard offset < reply.count,
                          ((length & 0x3f) << 8 | Int(reply[offset])) < reply.count else { return false }
                    offset += 1; nameFinished = true; break
                }
                guard length <= 63, offset + length <= reply.count else { return false }
                offset += length
            }
            guard nameFinished, offset + 10 <= reply.count else { return false }
            let type = word(offset), recordClass = word(offset + 2), length = word(offset + 8)
            offset += 10
            guard offset + length <= reply.count else { return false }
            if type == 1, recordClass == 1, length == 4 {
                let address = reply[offset..<offset + 4].map(String.init).joined(separator: ".")
                // Surge fake-IP answers do not demonstrate a working phone DNS path.
                let fake = reply[offset] == 198 && (reply[offset + 1] == 18 || reply[offset + 1] == 19)
                found = found || (SurgeConfiguration.validIPv4(address) && !fake)
            }
            offset += length
        }
        return found
    }

    private static func query(server: String, interface: String, timeout: TimeInterval) -> Result {
        func failure(_ operation: String) -> Result {
            let code = errno
            let denied = [EPIPE, EPERM, EACCES, EHOSTUNREACH].contains(code) && LocalNetworkAccess.denied(server: server)
            let detail = "\(operation) errno=\(code) \(String(cString: strerror(code)))"
            return Result(ready: false, detail: denied
                ? "macOS local network access denied. Allow HoRNDIS Status in Privacy & Security > Local Network. \(detail)"
                : detail, localNetworkDenied: denied)
        }
        let descriptor = openSocket()
        guard descriptor >= 0 else { return failure("socket") }
        defer { close(descriptor) }
        var index = if_nametoindex(interface)
        guard index != 0,
              setsockopt(descriptor, IPPROTO_IP, IP_BOUND_IF, &index,
                         socklen_t(MemoryLayout.size(ofValue: index))) == 0 else { return failure("bind interface \(interface)") }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(53).bigEndian
        guard inet_pton(AF_INET, server, &address.sin_addr) == 1 else { return failure("DNS address") }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return failure("connect") }
        let identifier = UInt16.random(in: 1...UInt16.max)
        var request: [UInt8] = [UInt8(identifier >> 8), UInt8(identifier & 255), 1, 0, 0, 1, 0, 0, 0, 0, 0, 0]
        for label in ["example", "com"] { request.append(UInt8(label.utf8.count)); request += label.utf8 }
        request += [0, 0, 1, 0, 1]
        guard request.withUnsafeBytes({ Darwin.send(descriptor, $0.baseAddress, $0.count, 0) }) == request.count else { return failure("send") }
        var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        let polled = poll(&pollDescriptor, 1, Int32(timeout * 1000))
        if polled < 0 { return failure("poll") }
        if polled == 0 { return Result(ready: false, detail: "response timeout") }
        var response = [UInt8](repeating: 0, count: 4096)
        let length = response.withUnsafeMutableBytes { recv(descriptor, $0.baseAddress, $0.count, 0) }
        guard length > 0 else { return failure("receive") }
        let bytes = Array(response.prefix(length))
        guard accepts(bytes, query: request) else {
            let code = length >= 4 ? Int(bytes[3] & 15) : -1
            return Result(ready: false, detail: "rejected DNS response length=\(length) rcode=\(code)")
        }
        return Result(ready: true, detail: "DNS response verified through \(interface)")
    }
}
