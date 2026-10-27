// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Network

enum LocalNetworkAccess {
    private static let lock = NSLock()
    private static var lastServer = ""
    private static var lastCheck: TimeInterval = 0
    private static var lastDenied = false

    private final class Outcome: @unchecked Sendable {
        let lock = NSLock()
        var denied = false
        var sent = false
        func observe(_ path: NWPath?) {
            guard path?.unsatisfiedReason == .localNetworkDenied else { return }
            lock.lock(); denied = true; lock.unlock()
        }
        func shouldSend() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if sent { return false }; sent = true; return true
        }
        var isDenied: Bool { lock.lock(); defer { lock.unlock() }; return denied }
    }

    // Only classify the OS policy after a failed BSD operation. A successful NW
    // path never substitutes for the real interface-bound DNS response check.
    static func denied(server: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        if lastServer == server && now - lastCheck < 10 { return lastDenied }
        let connection = NWConnection(host: NWEndpoint.Host(server), port: 53, using: .udp)
        let result = Outcome()
        let done = DispatchSemaphore(value: 0)
        connection.pathUpdateHandler = { path in
            result.observe(path)
            if result.isDenied { done.signal() }
        }
        connection.stateUpdateHandler = { state in
            result.observe(connection.currentPath)
            switch state {
            case .ready:
                if result.shouldSend() {
                    // example.com A query, sent only to the already-discovered DHCP DNS.
                    let query: [UInt8] = [0x73,0x11,1,0,0,1,0,0,0,0,0,0,7,101,120,97,109,112,108,101,3,99,111,109,0,0,1,0,1]
                    connection.send(content: Data(query), completion: .contentProcessed { _ in
                        result.observe(connection.currentPath); done.signal()
                    })
                }
            case .waiting, .failed, .cancelled: done.signal()
            default: break
            }
        }
        connection.start(queue: .global(qos: .utility))
        _ = done.wait(timeout: .now() + 1)
        result.observe(connection.currentPath)
        connection.stateUpdateHandler = nil
        connection.pathUpdateHandler = nil
        connection.cancel()
        lastServer = server; lastCheck = now; lastDenied = result.isDenied
        return lastDenied
    }
}
