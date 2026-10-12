// Codex / ChatGPT-owned. All fixtures and race sentinels stay in the checkout.
import Foundation
import Darwin

@main
struct LocalStoreTests {
    static var checks = 0

    static func main() {
        do { try run() }
        catch { fputs("LocalStore test failed: unexpected error \(error)\n", stderr); exit(1) }
    }

    static func expect(_ value: @autoclosure () -> Bool, _ detail: String) {
        checks += 1
        if !value() { fputs("LocalStore test failed: \(detail)\n", stderr); exit(1) }
    }

    static func rejects(_ detail: String, _ operation: () throws -> Void) {
        do { try operation(); expect(false, detail) }
        catch { expect(true, detail) }
    }

    static func run() throws {
        try LocalStore.validate(LocalStore.boundary)
        expect(true, "configured checkout itself is an allowed root")
        rejects("parent of checkout is outside the boundary") {
            try LocalStore.validate(LocalStore.boundary.deletingLastPathComponent())
        }
        rejects("matching prefix is not a checkout descendant") {
            try LocalStore.validate(URL(fileURLWithPath: LocalStore.boundary.path + "-unrelated"))
        }
        let root = LocalStore.boundary.appendingPathComponent(".build/test-work/local-\(UUID().uuidString)", isDirectory: true)
        try LocalStore.validate(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let runtime = root.appendingPathComponent(".runtime", isDirectory: true)
        let cache = runtime.appendingPathComponent("codex-usage.json")
        expect(LocalStore.read("codex-usage.json", root: root) == nil, "missing cache is unavailable")
        expect(!FileManager.default.fileExists(atPath: runtime.path), "read does not create runtime")
        let sample = ProviderSnapshot(providerID: "codex", title: "ChatGPT", subtitle: "Codex account limits",
            windows: [UsageWindow(label: "Current session", usedPercent: 19, resetsAt: Date(timeIntervalSince1970: 1_800_000_000), windowMinutes: 300)],
            updatedAt: Date(timeIntervalSince1970: 1_790_000_000), message: nil)
        try LocalStore.write(sample, name: "codex-usage.json", root: root)
        expect(LocalStore.read("codex-usage.json", root: root)?.windows.first?.usedPercent == 19, "snapshot round trip")
        let attributes = try FileManager.default.attributesOfItem(atPath: cache.path)
        expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "cache private permissions")
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: runtime.path)
        expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700, "new directory private permissions")
        try LocalStore.writeData(Data("approved\n".utf8), name: "live-enabled", root: root)
        expect(LocalStore.readData("live-enabled", root: root) == Data("approved\n".utf8), "bounded raw marker round trip")

        rejects("outside root write refused") { try LocalStore.write(sample, name: "codex-usage.json", root: URL(fileURLWithPath: "/private/tmp")) }
        rejects("traversal name refused") { try LocalStore.write(sample, name: "../escaped.json", root: root) }
        rejects("absolute name refused") { try LocalStore.write(sample, name: "/escaped.json", root: root) }
        rejects("empty name refused") { try LocalStore.write(sample, name: "", root: root) }
        rejects("NUL name refused") { try LocalStore.write(sample, name: "cache\0other", root: root) }
        rejects("oversized write refused") { try LocalStore.writeData(Data(repeating: 0, count: LocalStore.maximumBytes + 1), name: "large", root: root) }
        expect(LocalStore.readData("../escaped.json", root: root) == nil, "traversal read refused")

        let linkedRoot = root.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: root)
        rejects("root symlink refused") { try LocalStore.write(sample, name: "codex-usage.json", root: linkedRoot) }
        expect(LocalStore.readData("codex-usage.json", root: linkedRoot) == nil, "linked root read refused")
        rejects("symlink preflight refused") { try LocalStore.validate(linkedRoot) }

        let preserved = root.appendingPathComponent("preserved")
        try Data("untouched".utf8).write(to: preserved)
        let linkedFile = runtime.appendingPathComponent("linked-file")
        try FileManager.default.createSymbolicLink(at: linkedFile, withDestinationURL: preserved)
        rejects("cache symlink refused") { try LocalStore.writeData(Data("changed".utf8), name: "linked-file", root: root) }
        expect(LocalStore.readData("linked-file", root: root) == nil, "cache symlink read refused")
        let hardlink = runtime.appendingPathComponent("hardlinked")
        try FileManager.default.linkItem(at: preserved, to: hardlink)
        rejects("cache hardlink refused") { try LocalStore.writeData(Data("changed".utf8), name: "hardlinked", root: root) }
        expect(LocalStore.readData("hardlinked", root: root) == nil, "cache hardlink read refused")
        let preservedContents = try Data(contentsOf: preserved)
        expect(preservedContents == Data("untouched".utf8), "linked targets unchanged")

        let oversized = runtime.appendingPathComponent("oversized")
        try Data(repeating: 0, count: LocalStore.maximumBytes + 1).write(to: oversized)
        expect(LocalStore.readData("oversized", root: root) == nil, "oversized read refused")
        let fifo = runtime.appendingPathComponent("fifo")
        guard mkfifo(fifo.path, mode_t(0o600)) == 0 else { throw LocalStoreError.invalidData }
        expect(LocalStore.readData("fifo", root: root) == nil, "FIFO read refuses without blocking")
        rejects("FIFO write refused") { try LocalStore.writeData(Data(), name: "fifo", root: root) }

        // Repeated atomic swaps exercise the exact check/use race. The decoy is
        // deliberately inside our permitted workspace, so a regression cannot
        // write outside the user's boundary even while this test detects it.
        let decoy = root.appendingPathComponent("decoy", isDirectory: true)
        try FileManager.default.createDirectory(at: decoy, withIntermediateDirectories: true)
        let sentinel = Data("DO-NOT-READ-OR-CHANGE".utf8)
        let decoyCache = decoy.appendingPathComponent("codex-usage.json")
        try sentinel.write(to: decoyCache)
        let swap = root.appendingPathComponent(".runtime-swap")
        try FileManager.default.createSymbolicLink(at: swap, withDestinationURL: decoy)
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            for _ in 0..<300 {
                _ = renameatx_np(AT_FDCWD, runtime.path, AT_FDCWD, swap.path, UInt32(RENAME_SWAP))
            }
            group.leave()
        }
        for _ in 0..<100 {
            try? LocalStore.write(sample, name: "codex-usage.json", root: root)
            expect(LocalStore.readData("codex-usage.json", root: root) != sentinel, "race cannot read through symlink")
        }
        group.wait()
        let decoyContents = try Data(contentsOf: decoyCache)
        expect(decoyContents == sentinel, "race cannot change symlink destination")
        let finalDirectoryAttributes = try FileManager.default.attributesOfItem(atPath: runtime.path)
        if finalDirectoryAttributes[.type] as? FileAttributeType == .typeSymbolicLink {
            guard renameatx_np(AT_FDCWD, runtime.path, AT_FDCWD, swap.path, UInt32(RENAME_SWAP)) == 0 else {
                throw LocalStoreError.invalidData
            }
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: runtime.path)
        expect(!names.contains(where: { $0.hasPrefix(".usage-") }), "atomic writes leave no temporary files")
        print("LocalStore: \(checks) checks passed. Fixtures: \(root.path)")
    }
}
