import Foundation
import Darwin

struct UsageWindow: Codable {
    var label: String
    var usedPercent: Double
    var resetsAt: Date?
    var windowMinutes: Int?
}

struct ProviderSnapshot: Codable {
    var providerID: String
    var title: String
    var subtitle: String
    var windows: [UsageWindow]
    var updatedAt: Date?
    var message: String?
    // A request completion time is not necessarily the provider's measurement
    // time. Claude's experimental usage interface can return cached limits.
    var checkedOnDemand: Bool? = nil

    func displayWindows(at now: Date = Date()) -> [UsageWindow] {
        guard let updatedAt, updatedAt <= now.addingTimeInterval(60) else { return [] }
        return windows.filter {
            $0.usedPercent.isFinite && (0...100).contains($0.usedPercent)
                && ($0.resetsAt.map { $0 > now } ?? true)
        }
    }

    func freshness(at now: Date = Date()) -> String {
        guard let updatedAt else { return "Not connected yet" }
        let seconds = now.timeIntervalSince(updatedAt)
        if seconds < -60 { return "Update time unavailable" }
        let verb = providerID == "claude" ? (checkedOnDemand == true ? "Checked" : "Saved") : "Updated"
        if seconds < 60 { return "\(verb) just now" }
        if seconds < 3600 { return "\(verb) \(Int(seconds / 60))m ago" }
        if seconds < 86400 { return "\(verb) \(Int(seconds / 3600))h ago · may be outdated" }
        return "\(verb) \(Int(seconds / 86400))d ago · may be outdated"
    }

    static var codexUnavailable: ProviderSnapshot {
        ProviderSnapshot(providerID: "codex", title: "ChatGPT", subtitle: "Codex account limits", windows: [], updatedAt: nil, message: "Connect Codex to see your allowance.")
    }
}

enum LocalStoreError: Error { case unsafePath, invalidData }

enum LocalStore {
    // The built app records its checkout location. Standalone tools/tests can
    // select a checkout explicitly, or use their current working directory.
    // Never resolve symlinks here: validation rejects linked path components.
    static let boundary: URL = {
        let path = (Bundle.main.object(forInfoDictionaryKey: "LilTokenProjectRoot") as? String)
            ?? ProcessInfo.processInfo.environment["LIL_TOKEN_PROJECT_ROOT"]
            ?? FileManager.default.currentDirectoryPath
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }()
    static let maximumBytes = 65_536

    /// A preflight check for UI/setup. Actual I/O independently traverses with
    /// directory descriptors; this check alone does not authorize path-based I/O.
    static func validate(_ url: URL) throws {
        let parts = try checkedComponents(url)
        var fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw LocalStoreError.unsafePath }
        defer { Darwin.close(fd) }
        for (index, part) in parts.enumerated() {
            var info = stat()
            if fstatat(fd, part, &info, AT_SYMLINK_NOFOLLOW) != 0 {
                if errno == ENOENT { return }
                throw LocalStoreError.unsafePath
            }
            let kind = info.st_mode & S_IFMT
            guard kind == S_IFDIR || (kind == S_IFREG && info.st_nlink == 1 && index == parts.count - 1) else {
                throw LocalStoreError.unsafePath
            }
            if index == parts.count - 1 { return }
            let next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw LocalStoreError.unsafePath }
            Darwin.close(fd)
            fd = next
        }
    }

    static func read(_ name: String, root: URL) -> ProviderSnapshot? {
        guard let data = readData(name, root: root) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(ProviderSnapshot.self, from: data)
    }

    static func readData(_ name: String, root: URL) -> Data? {
        guard safeName(name), let directory = try? RuntimeDirectory(root: root, create: false) else { return nil }
        return try? directory.read(name)
    }

    static func write(_ snapshot: ProviderSnapshot, name: String, root: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        try writeData(data, name: name, root: root)
    }

    static func writeData(_ data: Data, name: String, root: URL) throws {
        guard safeName(name) else { throw LocalStoreError.unsafePath }
        guard data.count <= maximumBytes else { throw LocalStoreError.invalidData }
        let directory = try RuntimeDirectory(root: root, create: true)
        try directory.write(data, name: name)
    }

    private static func safeName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\") && !name.contains("\0")
    }

    private static func checkedComponents(_ url: URL) throws -> [String] {
        let path = url.standardizedFileURL.path
        guard url.isFileURL, !path.contains("\0"), boundary.path != "/",
              path == boundary.path || path.hasPrefix(boundary.path + "/") else {
            throw LocalStoreError.unsafePath
        }
        return path.split(separator: "/").map(String.init)
    }

    private final class RuntimeDirectory {
        private let descriptor: Int32

        init(root: URL, create: Bool) throws {
            let components = try checkedComponents(root)
            var fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw LocalStoreError.unsafePath }
            defer { Darwin.close(fd) }
            // O_NOFOLLOW applies to every ancestor, not just the final root.
            // Replacing any path component with a symlink cannot redirect I/O.
            for part in components {
                let next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw LocalStoreError.unsafePath }
                Darwin.close(fd)
                fd = next
            }
            if create, mkdirat(fd, ".runtime", mode_t(0o700)) != 0, errno != EEXIST {
                throw LocalStoreError.unsafePath
            }
            let runtime = openat(fd, ".runtime", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard runtime >= 0 else { throw LocalStoreError.unsafePath }
            descriptor = runtime
        }
        deinit { Darwin.close(descriptor) }

        func read(_ name: String) throws -> Data {
            let fd = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard fd >= 0 else { throw LocalStoreError.unsafePath }
            defer { Darwin.close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1,
                  info.st_size >= 0, info.st_size <= maximumBytes else { throw LocalStoreError.invalidData }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let amount = Darwin.read(fd, &buffer, buffer.count)
                if amount < 0 && errno == EINTR { continue }
                guard amount >= 0 else { throw LocalStoreError.invalidData }
                if amount == 0 { return data }
                data.append(contentsOf: buffer.prefix(amount))
                guard data.count <= maximumBytes else { throw LocalStoreError.invalidData }
            }
        }

        func write(_ data: Data, name: String) throws {
            var existing = stat()
            if fstatat(descriptor, name, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
                guard (existing.st_mode & S_IFMT) == S_IFREG, existing.st_nlink == 1 else {
                    throw LocalStoreError.unsafePath
                }
            } else if errno != ENOENT { throw LocalStoreError.unsafePath }

            let temporary = ".usage-\(UUID().uuidString).tmp"
            let fd = openat(descriptor, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
            guard fd >= 0 else { throw LocalStoreError.invalidData }
            defer {
                Darwin.close(fd)
                unlinkat(descriptor, temporary, 0)
            }
            try data.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                var offset = 0
                while offset < data.count {
                    let amount = Darwin.write(fd, base.advanced(by: offset), data.count - offset)
                    if amount < 0 && errno == EINTR { continue }
                    guard amount > 0 else { throw LocalStoreError.invalidData }
                    offset += amount
                }
            }
            guard fsync(fd) == 0, renameat(descriptor, temporary, descriptor, name) == 0 else {
                throw LocalStoreError.invalidData
            }
        }
    }
}
