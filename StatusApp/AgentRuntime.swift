// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin

enum AgentRuntime {
    private static let logLock = NSLock()
    static let maximumLogBytes = 1024 * 1024

    static func configureSignals() {
        // A denied local-network UDP send can return EPIPE and raise a process
        // SIGPIPE. Surface the policy failure instead of terminating the agent.
        signal(SIGPIPE, SIG_IGN)
    }

    static func writeStandardError(_ message: String) {
        try? FileHandle.standardError.write(contentsOf: Data((message + "\n").utf8))
    }

    static func log(_ message: String, storage: SurgeStorage) {
        logLock.lock()
        defer { logLock.unlock() }
        try? FileManager.default.createDirectory(at: storage.directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let path = storage.directory.path + "/agent.log"
        let previous = path + ".1"
        let clean = message.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        let date = ISO8601DateFormatter().string(from: Date())
        let data = Data("\(date) pid=\(getpid()) \(clean.prefix(1800))\n".utf8)
        var metadata = stat()
        if lstat(path, &metadata) == 0 {
            guard metadata.st_mode & S_IFMT == S_IFREG else { return }
            if metadata.st_size + Int64(data.count) > Int64(maximumLogBytes) {
                _ = unlink(previous)
                guard rename(path, previous) == 0 else { return }
            }
        }
        let descriptor = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        _ = fchmod(descriptor, 0o600)
        data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                if count <= 0 { break }
                offset += count
            }
        }
    }
}
