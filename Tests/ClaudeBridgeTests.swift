// Codex / ChatGPT-owned. All fixtures remain under Lil Token/.build/test-work.
import Foundation
import Darwin

@main
struct ClaudeBridgeTests {
    static var checks = 0
    static let base = Date(timeIntervalSince1970: 1_790_899_200)

    static func expect(_ condition: @autoclosure () -> Bool, _ detail: String) {
        checks += 1
        if !condition() { fputs("ClaudeBridge test failed: \(detail)\n", stderr); exit(1) }
    }

    static func main() {
        do { try run() }
        catch { fputs("ClaudeBridge test failed: unexpected error \(error)\n", stderr); exit(1) }
    }

    static func run() throws {
        let root = LocalStore.boundary
            .appendingPathComponent(".build/test-work/claude-\(UUID().uuidString)")
        try LocalStore.validate(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let first = ClaudeBridge.read(projectRoot: root, now: base)
        expect(first.windows.isEmpty && first.updatedAt == nil, "initial read is unavailable rather than zero")
        expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".runtime").path), "read does not create directories")

        let initialInput = payload(five: 19.4, week: 83.2, extra: ",\"session_id\":\"SENSITIVE-SESSION\",\"transcript_path\":\"SENSITIVE-PATH\",\"credentials\":\"SENSITIVE-TOKEN\"")
        let status = try ClaudeBridge.consume(input: initialInput, projectRoot: root, now: base)
        expect(status == "Claude · 5h 19% used · week 83% used", "short terminal status")
        let current = ClaudeBridge.read(projectRoot: root, now: base.addingTimeInterval(5))
        expect(current.windows.count == 2, "both windows imported")
        expect(current.windows[0].usedPercent == 19.4 && current.windows[1].usedPercent == 83.2, "precision retained")
        expect(current.windows[0].resetsAt == base.addingTimeInterval(3600), "epoch seconds parsed")
        expect(current.updatedAt == base, "receipt timestamp retained")
        let cache = root.appendingPathComponent(".runtime/claude-usage.json")
        let original = try Data(contentsOf: cache)
        let cacheText = String(decoding: original, as: UTF8.self)
        expect(!cacheText.contains("SENSITIVE") && !cacheText.contains("transcript"), "sensitive extra fields never persisted")
        let attributes = try FileManager.default.attributesOfItem(atPath: cache.path)
        expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "cache is owner-only")
        _ = try ClaudeBridge.consume(input: initialInput, projectRoot: root, now: base.addingTimeInterval(30))
        expect(tryData(cache) == original, "replayed measurements do not refresh receipt time")

        let missing = try ClaudeBridge.consume(input: Data("{}".utf8), projectRoot: root, now: base.addingTimeInterval(60))
        expect(missing.hasSuffix(" · cached"), "missing input reports cached status")
        let afterMissing = try Data(contentsOf: cache)
        expect(afterMissing == original, "missing fields preserve prior cache and timestamp")
        _ = try ClaudeBridge.consume(input: Data("{\"rate_limits\":{\"five_hour\":null,\"seven_day\":null}}".utf8), projectRoot: root, now: base.addingTimeInterval(90))
        expect(tryData(cache) == original, "null windows do not overwrite")

        let invalid = Data("{\"rate_limits\":{\"five_hour\":{\"used_percentage\":101,\"resets_at\":\(base.timeIntervalSince1970 + 10)}}}".utf8)
        _ = try ClaudeBridge.consume(input: invalid, projectRoot: root, now: base)
        expect(tryData(cache) == original, "out-of-range percentage preserves prior cache")
        let expired = payload(five: 20, week: nil, fiveReset: base.timeIntervalSince1970 - 1)
        _ = try ClaudeBridge.consume(input: expired, projectRoot: root, now: base)
        expect(tryData(cache) == original, "expired sample preserves prior cache")
        let farFuture = payload(five: 20, week: nil, fiveReset: base.timeIntervalSince1970 + 60_000)
        _ = try ClaudeBridge.consume(input: farFuture, projectRoot: root, now: base)
        expect(tryData(cache) == original, "implausible reset rejected")

        let stale = ClaudeBridge.read(projectRoot: root, now: base.addingTimeInterval(1000))
        expect(stale.windows.count == 2 && stale.message?.contains("Last known") == true, "stale sample identified")
        let reset = ClaudeBridge.read(projectRoot: root, now: base.addingTimeInterval(3601))
        expect(reset.windows.count == 1 && reset.windows[0].windowMinutes == 10_080, "expired short window suppressed")
        expect(reset.message?.contains("has reset") == true, "reset does not imply zero")
        let allReset = ClaudeBridge.read(projectRoot: root, now: base.addingTimeInterval(172_801))
        expect(allReset.windows.isEmpty && allReset.message?.contains("have reset") == true, "all expired windows suppressed")
        let clockError = ClaudeBridge.read(projectRoot: root, now: base.addingTimeInterval(-120))
        expect(clockError.windows.isEmpty && clockError.updatedAt == nil, "future received time is rejected")

        _ = try ClaudeBridge.consume(input: payload(five: nil, week: 84), projectRoot: root, now: base.addingTimeInterval(120))
        let partial = ClaudeBridge.read(projectRoot: root, now: base.addingTimeInterval(121))
        expect(partial.windows.count == 1 && partial.windows[0].windowMinutes == 10_080, "partial update does not falsely refresh previous window")
        expect(partial.updatedAt == base.addingTimeInterval(120), "valid partial update has its own timestamp")

        var live = ProviderSnapshot(providerID: "claude", title: "Untrusted title", subtitle: "Untrusted subtitle",
                                    windows: [UsageWindow(label: "Untrusted label", usedPercent: 85,
                                                          resetsAt: base.addingTimeInterval(172_800), windowMinutes: 10_080)],
                                    updatedAt: base.addingTimeInterval(150), message: nil)
        live.checkedOnDemand = true
        try LocalStore.write(live, name: "claude-live-usage.json", root: root)
        _ = try ClaudeBridge.consume(input: payload(five: nil, week: 83), projectRoot: root, now: base.addingTimeInterval(180))
        let display = ClaudeBridge.readForDisplay(projectRoot: root, allowOnDemand: true, now: base.addingTimeInterval(181))
        expect(display.windows.first?.usedPercent == 85 && display.updatedAt == live.updatedAt,
               "later passive replay cannot replace an on-demand check")
        expect(display.title == "Claude" && display.windows.first?.label == "This week", "live cache labels are normalized")
        expect(display.freshness(at: base.addingTimeInterval(181)) == "Checked just now", "check time is not claimed as measurement time")
        let disabled = ClaudeBridge.readForDisplay(projectRoot: root, allowOnDemand: false, now: base.addingTimeInterval(181))
        expect(disabled.windows.first?.usedPercent == 83 && disabled.checkedOnDemand != true, "live cache requires activation")
        expect(disabled.freshness(at: base.addingTimeInterval(181)) == "Saved just now", "passive receipt clearly labelled saved")
        live.updatedAt = base.addingTimeInterval(190)
        try LocalStore.write(live, name: "claude-live-usage.json", root: root)
        expect(ClaudeBridge.readForDisplay(projectRoot: root, allowOnDemand: true, now: base.addingTimeInterval(191)).updatedAt == live.updatedAt,
               "successful on-demand check can retain percentage with new check time")
        _ = try ClaudeBridge.consume(input: payload(five: nil, week: 85), projectRoot: root, now: base.addingTimeInterval(200))
        expect(ClaudeBridge.readForDisplay(projectRoot: root, allowOnDemand: true, now: base.addingTimeInterval(201)).checkedOnDemand == true,
               "later identical passive report does not disguise live check age")
        _ = try ClaudeBridge.consume(input: payload(five: nil, week: 86), projectRoot: root, now: base.addingTimeInterval(210))
        let advanced = ClaudeBridge.readForDisplay(projectRoot: root, allowOnDemand: true, now: base.addingTimeInterval(211))
        expect(advanced.windows.first?.usedPercent == 86 && advanced.checkedOnDemand != true && advanced.updatedAt == base.addingTimeInterval(210),
               "later higher same-window passive report remains useful after live failure")
        live.windows[0].resetsAt = base.addingTimeInterval(172_800.075)
        try LocalStore.write(live, name: "claude-live-usage.json", root: root)
        expect(ClaudeBridge.readForDisplay(projectRoot: root, allowOnDemand: true, now: base.addingTimeInterval(211)).windows.first?.usedPercent == 86,
               "fractional live reset matches statusline whole-second epoch")
        let differentReset = Data("{\"rate_limits\":{\"seven_day\":{\"used_percentage\":87,\"resets_at\":\(base.timeIntervalSince1970 + 172_801)}}}".utf8)
        _ = try ClaudeBridge.consume(input: differentReset, projectRoot: root, now: base.addingTimeInterval(220))
        expect(ClaudeBridge.readForDisplay(projectRoot: root, allowOnDemand: true, now: base.addingTimeInterval(221)).checkedOnDemand == true,
               "different reset is not treated as monotonic progress")
        _ = try ClaudeBridge.consume(input: payload(five: nil, week: 83), projectRoot: root, now: base.addingTimeInterval(230))
        live.windows[0].usedPercent = 101
        try LocalStore.write(live, name: "claude-live-usage.json", root: root)
        expect(ClaudeBridge.readForDisplay(projectRoot: root, allowOnDemand: true, now: base.addingTimeInterval(231)).windows.first?.usedPercent == 83,
               "invalid live cache falls back to saved report")
        live.windows[0].usedPercent = 85
        live.updatedAt = base.addingTimeInterval(1000)
        try LocalStore.write(live, name: "claude-live-usage.json", root: root)
        expect(ClaudeBridge.readForDisplay(projectRoot: root, allowOnDemand: true, now: base.addingTimeInterval(231)).windows.first?.usedPercent == 83,
               "future live check does not mask saved report")
        live.updatedAt = base.addingTimeInterval(190)
        live.windows[0] = UsageWindow(label: "session", usedPercent: 5, resetsAt: base.addingTimeInterval(3600), windowMinutes: 300)
        try LocalStore.write(live, name: "claude-live-usage.json", root: root)
        expect(ClaudeBridge.readForDisplay(projectRoot: root, allowOnDemand: true, now: base.addingTimeInterval(3601)).windows.first?.usedPercent == 83,
               "expired live windows fall back to still-valid saved report")

        try expectThrows("malformed JSON rejected") { _ = try ClaudeBridge.consume(input: Data("{SECRET".utf8), projectRoot: root, now: base) }
        try expectThrows("oversized input rejected") { _ = try ClaudeBridge.consume(input: Data(repeating: 32, count: ClaudeBridge.maximumInputBytes + 1), projectRoot: root, now: base) }
        try expectThrows("boolean percentage rejected") { _ = try ClaudeBridge.consume(input: Data("{\"rate_limits\":{\"five_hour\":{\"used_percentage\":true,\"resets_at\":1790900000}}}".utf8), projectRoot: root, now: base) }
        try expectThrows("outside project path rejected before write") { _ = try ClaudeBridge.consume(input: initialInput, projectRoot: URL(fileURLWithPath: "/private/tmp"), now: base) }

        let linked = root.appendingPathComponent("linked-runtime")
        try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
        let decoy = root.appendingPathComponent("runtime-decoy", isDirectory: true)
        try FileManager.default.createDirectory(at: decoy, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: linked.appendingPathComponent(".runtime"), withDestinationURL: decoy)
        try expectThrows("linked runtime rejected before write") { _ = try ClaudeBridge.consume(input: initialInput, projectRoot: linked, now: base) }

        let target = root.appendingPathComponent("link-target.json")
        try Data("untouched".utf8).write(to: target)
        try FileManager.default.removeItem(at: cache)
        try FileManager.default.createSymbolicLink(at: cache, withDestinationURL: target)
        try expectThrows("linked cache rejected") { _ = try ClaudeBridge.consume(input: initialInput, projectRoot: root, now: base) }
        expect(tryData(target) == Data("untouched".utf8), "linked destination left untouched")
        expect(ClaudeBridge.read(projectRoot: root, now: base).windows.isEmpty, "read refuses linked cache")
        print("ClaudeBridge: \(checks) checks passed. Fixtures: \(root.path)")
    }

    static func tryData(_ url: URL) -> Data? { try? Data(contentsOf: url) }
    static func expectThrows(_ detail: String, _ operation: () throws -> Void) throws {
        do { try operation(); expect(false, detail) }
        catch { expect(true, detail) }
    }
    static func payload(five: Double?, week: Double?, fiveReset: Double? = nil, extra: String = "") -> Data {
        var fields = [String]()
        if let five { fields.append("\"five_hour\":{\"used_percentage\":\(five),\"resets_at\":\(fiveReset ?? base.timeIntervalSince1970 + 3600)}") }
        if let week { fields.append("\"seven_day\":{\"used_percentage\":\(week),\"resets_at\":\(base.timeIntervalSince1970 + 172800)}") }
        return Data("{\"rate_limits\":{\(fields.joined(separator: ","))}\(extra)}".utf8)
    }
}
