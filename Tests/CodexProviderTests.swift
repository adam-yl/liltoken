// Codex-owned. Standalone fixture tests; never launches the real Codex CLI.
import Foundation
import Darwin

@main
enum CodexProviderTests {
    static var checks = 0

    static func check(_ condition: @autoclosure () -> Bool, _ description: String) throws {
        checks += 1
        if !condition() { throw NSError(domain: "CodexProviderTests", code: 1,
                                       userInfo: [NSLocalizedDescriptionKey: description]) }
    }

    static func main() {
        do { try run() }
        catch {
            fputs("Codex provider test failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    static func run() throws {
        if CommandLine.arguments.count > 2, CommandLine.arguments[1] == "--mock-server" {
            mockServer(mode: CommandLine.arguments[2]); return
        }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let legacy: [String: Any] = ["rateLimits": [
            "primary": ["usedPercent": 19, "windowDurationMins": 300, "resetsAt": 1_800_003_000],
            "secondary": ["usedPercent": 83.5, "windowDurationMins": 10_080, "resetsAt": 1_800_080_000]
        ]]
        let decoded = try CodexProvider.decode(legacy, now: now)
        try check(decoded.windows.count == 2, "both usage windows")
        try check(decoded.providerID == "codex", "provider identity")
        try check(decoded.windows[0].usedPercent == 19, "used is not remaining")
        try check(decoded.windows[1].usedPercent == 83.5, "preserve fractional usage")
        try check(decoded.windows[0].label == "Current session", "five-hour label")
        try check(decoded.windows[1].label == "This week", "weekly label")
        try check(decoded.updatedAt == now, "record refresh time")
        try check(decoded.windows[0].resetsAt?.timeIntervalSince1970 == 1_800_003_000, "Unix seconds")
        let weeklyPrimary = try CodexProvider.decode(["rateLimits": ["primary": [
            "usedPercent": 4, "windowDurationMins": 10_080
        ]]], now: now)
        try check(weeklyPrimary.windows.first?.label == "This week", "weekly primary classified by duration")
        let preferred = try CodexProvider.decode([
            "rateLimits": ["primary": ["usedPercent": 91]],
            "rateLimitsByLimitId": [
                "other": ["primary": ["usedPercent": 80]],
                "codex": ["primary": ["usedPercent": 22, "windowDurationMins": 60]]
            ]
        ])
        try check(preferred.windows.first?.usedPercent == 22, "prefer multi-bucket codex")
        try check(preferred.windows.first?.label == "1-hour window", "nonstandard duration label")
        let empty = try CodexProvider.decode(["rateLimits": NSNull()])
        try check(empty.windows.isEmpty, "missing data is not zero")
        try check(empty.message != nil, "empty response explains unavailability")
        let wrongBucket = try CodexProvider.decode(["rateLimitsByLimitId": [
            "another_product": ["primary": ["usedPercent": 50]]
        ]])
        try check(wrongBucket.windows.isEmpty, "do not mislabel another service quota")
        let invalid = try CodexProvider.decode(["rateLimits": [
            "primary": ["usedPercent": true], "secondary": ["usedPercent": "42"]
        ]])
        try check(invalid.windows.isEmpty, "reject boolean and string percentages")
        let nonfinite = try CodexProvider.decode(["rateLimits": [
            "primary": ["usedPercent": Double.nan], "secondary": ["usedPercent": Double.infinity]
        ]])
        try check(nonfinite.windows.isEmpty, "reject nonfinite percentages")
        let limits = try CodexProvider.decode(["rateLimits": [
            "primary": ["usedPercent": -2, "windowDurationMins": true, "resetsAt": -1],
            "secondary": ["usedPercent": 120, "windowDurationMins": 1.5, "resetsAt": "tomorrow"]
        ]])
        try check(limits.windows.map(\.usedPercent) == [0, 100], "clamp numeric range")
        try check(limits.windows.allSatisfy { $0.windowMinutes == nil && $0.resetsAt == nil }, "invalid metadata stays absent")
        try check(limits.windows.map(\.label) == ["Primary window", "Secondary window"], "do not infer unknown durations")
        var malformedRejected = false
        do { _ = try CodexProvider.decode(["unrelated": 12]) } catch { malformedRejected = true }
        try check(malformedRejected, "reject unsupported envelope")

        let root = LocalStore.boundary
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let success = try runMock("success", executable: executable, root: root)
        let successSnapshot = try success.get()
        try check(successSnapshot.windows.first?.usedPercent == 37, "mock handshake and live JSONL framing")
        for mode in ["rpc-error", "bad-json", "overflow", "stderr-overflow", "early-exit"] {
            let result = try runMock(mode, executable: executable, root: root)
            switch result {
            case .success: try check(false, "\(mode) should fail")
            case .failure(let error):
                try check(!error.localizedDescription.contains("PRIVATE_TEST_MARKER"), "\(mode) never displays server secrets")
            }
        }
        let timeoutStart = Date()
        let timeout = try runMock("hang", executable: executable, root: root, timeout: 0.15)
        switch timeout {
        case .failure(let error): try check((error as? CodexProviderError) == .timedOut, "timeout error")
        case .success: try check(false, "timeout should fail")
        }
        try check(Date().timeIntervalSince(timeoutStart) < 3, "force-kill and reap bounded")
        let cancelled = try runMock("hang", executable: executable, root: root, cancel: true)
        switch cancelled {
        case .failure(let error): try check((error as? CodexProviderError) == .cancelled, "cancel completes exactly once")
        case .success: try check(false, "cancel should fail")
        }
        try testShutdown(executable: executable, root: root)
        print("Codex provider: \(checks) checks passed; only local mock processes used.")
    }

    static func testShutdown(executable: URL, root: URL) throws {
        let folder = root.appendingPathComponent(".build/tmp/shutdown-test-\(UUID().uuidString)", isDirectory: true)
        guard folder.resolvingSymlinksInPath() == folder else { throw CodexProviderError.unsafeRuntime }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let provider = CodexProvider(executableURL: executable,
                                     arguments: ["--mock-server", "hang-reported", folder.path], timeout: 10)
        var results: [Result<ProviderSnapshot, Error>] = []
        func pids() -> [pid_t] {
            ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).compactMap { Int32($0) }
        }
        func spin(until condition: () -> Bool) {
            let end = Date().addingTimeInterval(3)
            while !condition(), Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        }
        provider.fetch(projectRoot: root) { results.append($0) }
        spin { pids().count == 1 }
        try check(pids().count == 1, "first shutdown fixture running")
        provider.fetch(projectRoot: root) { results.append($0) }
        spin { pids().count == 2 }
        try check(pids().count == 2, "second shutdown fixture running while first is cancelling")
        let children = pids()
        var shutdowns = 0
        var callbackOnMain = false
        let start = Date()
        provider.shutdown { shutdowns += 1; callbackOnMain = Thread.isMainThread }
        spin { shutdowns == 1 }
        try check(shutdowns == 1 && callbackOnMain, "shutdown completes once on main")
        try check(Date().timeIntervalSince(start) < 2, "shutdown force-kill is bounded")
        try check(children.allSatisfy { Darwin.kill($0, 0) == -1 && errno == ESRCH }, "all child PIDs gone before shutdown callback")
        try check(results.count == 2, "both cancelled request completions precede shutdown")
        provider.shutdown { shutdowns += 1 }
        spin { shutdowns == 2 }
        try check(shutdowns == 2, "repeated shutdown is safe")
        provider.fetch(projectRoot: root) { results.append($0) }
        spin { results.count == 3 }
        try check(results.count == 3 && pids().count == 2, "fetch after shutdown starts no child")
        if case .failure(let error) = results.last! {
            try check((error as? CodexProviderError) == .cancelled, "fetch after shutdown rejected")
        } else { try check(false, "fetch after shutdown must fail") }
    }

    static func runMock(_ mode: String, executable: URL, root: URL,
                        timeout: TimeInterval = 2, cancel: Bool = false) throws -> Result<ProviderSnapshot, Error> {
        let provider = CodexProvider(executableURL: executable,
                                     arguments: ["--mock-server", mode], timeout: timeout)
        var results: [Result<ProviderSnapshot, Error>] = []
        provider.fetch(projectRoot: root) { results.append($0) }
        if cancel { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { provider.cancel() } }
        let deadline = Date().addingTimeInterval(5)
        while results.isEmpty, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        try check(results.count == 1, "\(mode) completes after child cleanup")
        return results[0]
    }

    static func mockServer(mode: String) {
        if mode == "hang" || mode == "hang-reported" {
            signal(SIGTERM, SIG_IGN)
            if mode == "hang-reported", CommandLine.arguments.count == 4 {
                let directory = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
                let file = directory.appendingPathComponent(String(getpid()))
                guard directory.resolvingSymlinksInPath() == directory,
                      directory.path.hasPrefix(FileManager.default.currentDirectoryPath + "/.build/tmp/") else { return }
                try? Data().write(to: file)
            }
            while true { sleep(1) }
        }
        if mode == "early-exit" { return }
        guard let first = readLine(), let initData = first.data(using: .utf8),
              let initialize = try? JSONSerialization.jsonObject(with: initData) as? [String: Any],
              initialize["method"] as? String == "initialize" else { return }
        if mode == "bad-json" { emit("not json\n"); return }
        if mode == "overflow" { emit(String(repeating: "x", count: 70_000)); while readLine() != nil {}; return }
        if mode == "stderr-overflow" {
            FileHandle.standardError.write(Data(repeating: 120, count: 600_000))
            while readLine() != nil {}; return
        }
        emit("{\"method\":\"unrelated/notification\",\"params\":{}}\n{\"id\":1,\"result\":{\"userAgent\":\"test\"}}\n")
        guard let notification = readLine(), let notifyData = notification.data(using: .utf8),
              let initialized = try? JSONSerialization.jsonObject(with: notifyData) as? [String: Any],
              initialized["method"] as? String == "initialized",
              let second = readLine(), let requestData = second.data(using: .utf8),
              let request = try? JSONSerialization.jsonObject(with: requestData) as? [String: Any],
              request["method"] as? String == "account/rateLimits/read" else { return }
        if mode == "rpc-error" {
            emit("{\"id\":2,\"error\":{\"code\":401,\"message\":\"PRIVATE_TEST_MARKER\"}}\n")
        } else {
            emit("{\"id\":2,\"result\":{\"rateLimits\":{\"primary\":")
            emit("{\"usedPercent\":37,\"windowDurationMins\":300}}}}\n")
        }
        while readLine() != nil {}
    }

    static func emit(_ value: String) { FileHandle.standardOutput.write(Data(value.utf8)) }
}
