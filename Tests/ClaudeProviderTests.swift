// Codex-owned. Uses this test executable as a mock; never launches real Claude.
import Foundation
import Darwin

@main
enum ClaudeProviderTests {
    static var checks = 0

    static func check(_ condition: @autoclosure () -> Bool, _ description: String) throws {
        checks += 1
        if !condition() { throw NSError(domain: "ClaudeProviderTests", code: 1,
                                        userInfo: [NSLocalizedDescriptionKey: description]) }
    }

    static func main() {
        if CommandLine.arguments.contains("--verify-installed-cli") {
            do {
                let url = try ClaudeProvider.resolvedInstalledCLIURL()
                print("Verified signed Claude CLI usage-only support at " + url.lastPathComponent)
                if CommandLine.arguments.contains("--hold-after-verify") {
                    fflush(stdout)
                    RunLoop.current.run(until: Date().addingTimeInterval(30))
                }
            } catch {
                fputs("Installed CLI check failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
            return
        }
        if CommandLine.arguments.count > 2, CommandLine.arguments[1] == "--mock-server" {
            mockServer(mode: CommandLine.arguments[2]); return
        }
        do { try run() }
        catch {
            fputs("Claude provider test failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    static func payload(now: Date, percent: Any = 37.5) -> [String: Any] {
        ["behaviors": NSNull(), "rate_limits_available": true, "rate_limits": [
            "five_hour": ["utilization": percent,
                          "resets_at": ISO8601DateFormatter().string(from: now.addingTimeInterval(3600))],
            "seven_day": ["utilization": 73,
                          "resets_at": ISO8601DateFormatter().string(from: now.addingTimeInterval(86400))]
        ]]
    }

    static func run() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let good = payload(now: now)
        let decoded = try ClaudeProvider.decode(good, now: now)
        try check(decoded.providerID == "claude" && decoded.title == "Claude", "fixed provider identity")
        try check(decoded.windows.count == 2, "both documented windows")
        try check(decoded.windows.map(\.usedPercent) == [37.5, 73], "fractional percentages preserved")
        try check(decoded.windows.map(\.windowMinutes) == [300, 10080], "fixed subscription durations")
        try check(decoded.windows.map(\.label) == ["Current session", "This week"], "normalized labels")
        try check(decoded.updatedAt == now, "record time the control answered")
        let again = try ClaudeProvider.decode(good, now: now.addingTimeInterval(20))
        try check(again.updatedAt == now.addingTimeInterval(20), "same value records a new completed check")
        for value: Any in [true, "37", Double.nan, Double.infinity, -1, 101] {
            let result = try ClaudeProvider.decode(payload(now: now, percent: value), now: now)
            try check(result.windows.count == 1 && result.windows[0].windowMinutes == 10080,
                      "invalid session percentage ignored without losing valid weekly data")
        }
        for reset: Any in [NSNull(), true, 1_800_003_600, "tomorrow",
                           "2027-01-15T08:00:00Z", ISO8601DateFormatter().string(from: now),
                           ISO8601DateFormatter().string(from: now.addingTimeInterval(18601))] {
            var bad = good
            bad["rate_limits"] = ["five_hour": ["utilization": 37, "resets_at": reset]]
            try expectDecodeError(bad, now: now, expected: .unavailable)
        }
        var fractional = good
        fractional["rate_limits"] = ["five_hour": ["utilization": 37, "resets_at": "2027-01-15T09:00:00.123Z"]]
        // Use a controlled base so the fractional reset is exactly in the five-hour window.
        let dateNow = ISO8601DateFormatter().date(from: "2027-01-15T08:00:00Z")!
        try check(tryDecodeCount(fractional, now: dateNow) == 1, "fractional ISO8601 reset accepted")
        for behaviors: Any in [[:], [], "ignored", true] {
            var bad = good; bad["behaviors"] = behaviors
            try expectDecodeError(bad, now: now, expected: .invalidResponse)
        }
        var absent = good; absent["behaviors"] = nil
        try expectDecodeError(absent, now: now, expected: .invalidResponse)
        for available: Any in [1, "true", NSNull()] {
            var bad = good; bad["rate_limits_available"] = available
            try expectDecodeError(bad, now: now, expected: .invalidResponse)
        }
        var unavailable = good; unavailable["rate_limits_available"] = false
        try expectDecodeError(unavailable, now: now, expected: .unavailable)
        var noReading = good; noReading["rate_limits"] = NSNull()
        try expectDecodeError(noReading, now: now, expected: .unavailable)
        for value: Any in ["PRIVATE_TEST_MARKER", true, []] {
            var bad = good; bad["rate_limits"] = value
            try expectDecodeError(bad, now: now, expected: .invalidResponse)
        }
        var empty = good; empty["rate_limits"] = ["five_hour": NSNull(), "seven_day": NSNull()]
        try expectDecodeError(empty, now: now, expected: .unavailable)
        var unsupported = good; unsupported["rate_limits"] = ["seven_day_opus": ["utilization": 34]]
        try expectDecodeError(unsupported, now: now, expected: .unavailable)

        let flags = ClaudeProvider.defaultArguments
        try check(flags.contains("--safe-mode"), "custom instructions/plugins disabled")
        try check(flags.contains("--no-session-persistence"), "session persistence disabled")
        try check(flags.contains("--no-chrome") && flags.contains("--strict-mcp-config"), "browser and MCP integration disabled")
        try check(flags.contains("{\"disableAllHooks\":true}"), "user-configured hooks disabled")
        try check(flags.contains("dontAsk") && flags.contains("none"), "permission interaction disabled")
        try check(flags.firstIndex(of: "--tools").map { flags[$0 + 1].isEmpty } == true, "no model tools")
        try check(ClaudeProvider.nativeCLIEntry == FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/claude"),
                  "native installer entry follows the current user, never PATH")
        try check(ClaudeProvider.nativeVersionsDirectory == FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/claude/versions", isDirectory: true),
                  "native versions directory follows the current user")
        try testCLICapabilities()
        try testCLIUpdates()
        let diagnostics = ClaudeProvider.diagnosticCategories(in: "PRIVATE_TEST_MARKER fetchUtilization: 403 remembered for this bearer; PRIVATE_TEST_MARKER")
        try check(diagnostics == ["HTTP 403"], "diagnostics emit fixed status only, never provider text")
        try check(ClaudeProvider.diagnosticCategories(in: "PRIVATE_TEST_MARKER").isEmpty, "unknown diagnostic content discarded")
        try check(ClaudeProvider.diagnosticCategories(in:
            "[keychain] readAsync failed; not caching a null PRIVATE_TEST_MARKER " +
            "[keychain] read failed; serving stale cache PRIVATE_TEST_MARKER " +
            "Credentials prime through the store failed (PRIVATE_TEST_MARKER)") == [
                "credential store read failed", "credential store cached fallback", "credential store priming failed"
            ], "credential store warnings classified without exposing diagnostic detail")
        let privateAccount: [String: Any] = ["account": [
            "email": "PRIVATE_TEST_MARKER", "organization": "PRIVATE_TEST_MARKER",
            "subscriptionType": "Claude Pro", "apiProvider": "firstParty", "tokenSource": "none"
        ]]
        let accountCategories = ClaudeProvider.accountDiagnosticCategories(in: privateAccount)
        try check(accountCategories.contains("Account: subscription Claude Pro"), "subscription status projected")
        try check(accountCategories.contains("Account: token source none"), "missing helper sign-in classified")
        try check(!accountCategories.joined().contains("PRIVATE_TEST_MARKER"), "private account identity discarded")
        try check(ClaudeProvider.accountDiagnosticCategories(in: ["account": [
            "subscriptionType": "PRIVATE_TEST_MARKER", "apiProvider": "PRIVATE_TEST_MARKER",
            "tokenSource": "PRIVATE_TEST_MARKER", "apiKeySource": "PRIVATE_TEST_MARKER"
        ]]).dropFirst().allSatisfy { $0.hasSuffix("unrecognized") }, "unknown account fields never echoed")
        try check(ClaudeProvider.accountDiagnosticCategories(in: [:]) == ["Account: status absent"], "absent account classified")
        try check(ClaudeProvider.accountDiagnosticCategories(in: ["account": NSNull()]) == ["Account: status absent"], "null account classified")

        let project = LocalStore.boundary
        let root = project.appendingPathComponent(".build/test-work/claude-provider-\(UUID().uuidString)", isDirectory: true)
        try LocalStore.validate(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        try check(!ClaudeProvider.isAuthorized(projectRoot: root), "missing authorization is disabled")
        try assertFailure(runMock("success", executable: executable, root: root), is: .notAuthorized)
        try check(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".build").path),
                  "unauthorized fetch creates no runtime or child")
        try LocalStore.writeData(Data("approved".utf8), name: "live-enabled", root: root)
        try assertFailure(runMock("success", executable: executable, root: root), is: .notAuthorized)
        try LocalStore.writeData(Data("approved\n".utf8), name: "claude-live-enabled", root: root)
        try check(!ClaudeProvider.isAuthorized(projectRoot: root), "authorization marker is exact")
        try LocalStore.writeData(Data("approved".utf8), name: "claude-live-enabled", root: root)
        try check(ClaudeProvider.isAuthorized(projectRoot: root), "separate exact marker enables mock")
        let restrictionKey = "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"
        let originalRestriction = ProcessInfo.processInfo.environment[restrictionKey]
        defer {
            if let originalRestriction { setenv(restrictionKey, originalRestriction, 1) }
            else { unsetenv(restrictionKey) }
        }
        for value in ["1", "0"] {
            setenv(restrictionKey, value, 1)
            try assertFailure(runMock("success", executable: executable, root: root), is: .privacyRestricted)
        }
        unsetenv(restrictionKey)
        let diagnosticKeys = ["DEBUG", "DEBUG_SDK", "BETA_TRACING", "OTEL_EXPORTER_FILE", "NODE_OPTIONS", "NODE_V8_COVERAGE"]
        let previousEnvironment = ProcessInfo.processInfo.environment
        for key in diagnosticKeys { setenv(key, "PRIVATE_TEST_MARKER", 1) }
        defer {
            for key in diagnosticKeys {
                if let value = previousEnvironment[key] { setenv(key, value, 1) }
                else { unsetenv(key) }
            }
        }
        let success = try runMock("success", executable: executable, root: root).get()
        try check(success.windows.first?.usedPercent == 37.5, "initialize then get_usage roundtrip")
        try check(success.windows.count == 2, "fragmented NDJSON response decoded")
        for (mode, failure) in [("init-error", ClaudeProviderError.unavailable),
                                ("usage-error", .unavailable), ("bad-json", .invalidResponse),
                                ("overflow", .outputLimit), ("stderr-overflow", .outputLimit),
                                ("unexpected-tool", .invalidResponse), ("behaviors", .invalidResponse),
                                ("early-exit", .unavailable)] {
            try assertFailure(runMock(mode, executable: executable, root: root), is: failure)
        }
        let start = Date()
        try assertFailure(runMock("hang", executable: executable, root: root, timeout: 0.15), is: .timedOut)
        try check(Date().timeIntervalSince(start) < 3, "timeout including SIGKILL and reap bounded")
        try assertFailure(runMock("hang", executable: executable, root: root, cancel: true), is: .cancelled)
        try testShutdown(executable: executable, root: root)

        let working = root.appendingPathComponent(".build/.runtime/claude/workspace")
        let unexpected = working.appendingPathComponent("CLAUDE.md")
        try LocalStore.validate(unexpected)
        try Data("fixture".utf8).write(to: unexpected)
        try assertFailure(runMock("success", executable: executable, root: root), is: .unsafeRuntime)
        try FileManager.default.removeItem(at: unexpected)
        let temp = root.appendingPathComponent(".build/.runtime/claude/tmp")
        try FileManager.default.removeItem(at: temp)
        try FileManager.default.createSymbolicLink(at: temp, withDestinationURL: root)
        try assertFailure(runMock("success", executable: executable, root: root), is: .unsafeRuntime)
        try FileManager.default.removeItem(at: temp)
        print("Claude live provider: \(checks) checks passed; only local mock processes used.")
    }

    // Representative source slices from the inspected signed 2.1.290 binary.
    // Negative cases model older controls and privacy-regressing updates.
    static let cliSchema = #"Po=f(()=>u({subtype:R("get_usage"),skip_behaviors:H().optional().describe("Skip the scan of local transcripts that produces the response's behaviors section (it is null in the answer). For callers that need only the plan rate limits.")}));"#
    static let cliHandler = #"Ve=async(e,o)=>{if(e.skip_behaviors!=null&&typeof e.skip_behaviors!=="boolean")throw new Tr("get_usage: skip_behaviors must be a boolean");return{...await Jin({storageV5:o.storageV5,credentials:o.credentials,includeBehaviors:!o.redactsPersistedLane()&&e.skip_behaviors!==!0})}};var Oe={mcp_status:qe,get_context_usage:Ne,get_usage:Ve,get_session_cost:ze};"#
    static let cliFunction = #"async function Jin({includeBehaviors:e=!0,storageV5:n,credentials:o}){let i=mt(),s=i&&_f(),[a,u]=await Promise.all([s?s6n(n,o):Promise.resolve(null),e&&i&&L$e().allowed?qMt(n).then((r)=>({day:g(r.day),week:g(r.week)}),(r)=>(c(r),null)):Promise.resolve(null)]),d=a?.status==="ok"||a?.status==="seeded"?a.utilization:null,p;if(d!==null)try{p=xyt(d.limits,Sse()).map((r)=>({display_name:r.displayName,utilization:r.limit.utilization??null,resets_at:typeof r.limit.resets_at==="number"?new Date(r.limit.resets_at*1000).toISOString():r.limit.resets_at??null}))}catch(r){t(`model_scoped projection failed: ${l(r)}`,{level:"error"})}let m=d;if(d!==null&&a?.status==="seeded"){let{limits:r,...v}=d;m=v}let z=p!==void 0&&a?.status==="ok"&&(a.utilization.five_hour!=null||a.utilization.seven_day!=null)&&Array.isArray(a.utilization.limits)&&!GVo(a.utilization.limits);return{session:{total_cost_usd:Ph(),total_api_duration_ms:HH(),total_duration_ms:qle(),total_lines_added:eAe(),total_lines_removed:tAe(),model_usage:iI()},subscription_type:cr(),rate_limits_available:s,rate_limits:d===null?null:p!==void 0&&p.length>0?{...m,model_scoped:p}:z?{...m,model_scoped:[]}:m,behaviors:u}}"#
    static var supportedCLI: String { cliSchema + cliHandler + cliFunction }

    static func hasCapability(_ text: String) -> Bool {
        var capability = ClaudeUsageCapability()
        capability.inspect(text)
        return capability.supported
    }

    static func testCLICapabilities() throws {
        try check(hasCapability(supportedCLI), "known control includes transcript gate and null result")
        try check(!hasCapability(cliSchema), "schema alone cannot authorize execution")
        try check(!hasCapability(cliHandler + cliFunction), "implementation without usage-only contract is rejected")
        try check(!hasCapability(cliSchema + cliFunction), "missing control handler is rejected")
        try check(!hasCapability(supportedCLI.replacingOccurrences(of: "get_usage:Ve,", with: "get_usage:Old,")),
                  "unconnected safe handler cannot authorize active unsafe control")
        try check(!hasCapability(supportedCLI.replacingOccurrences(of: "skip_behaviors!==!0", with: "skip_behaviors===!0")),
                  "inverted request gate fails closed")
        try check(!hasCapability(supportedCLI.replacingOccurrences(of: "includeBehaviors:!o.redactsPersistedLane()&&e.skip_behaviors!==!0", with: "includeBehaviors:!0")),
                  "always scan implementation fails closed")
        try check(!hasCapability(supportedCLI.replacingOccurrences(of: "e&&i&&L$e().allowed?", with: "i&&L$e().allowed?")),
                  "response generator ignoring includeBehaviors fails closed")
        try check(!hasCapability(supportedCLI.replacingOccurrences(of: "{let i=mt()", with: "{await qMt(n);let i=mt()")),
                  "unconditional transcript scan inserted before Promise.all fails closed")
        try check(!hasCapability(supportedCLI.replacingOccurrences(of: "s?s6n(n,o):Promise.resolve(null)", with: "s?(await qMt(n),s6n(n,o)):Promise.resolve(null)")),
                  "unconditional transcript scan in network branch fails closed")
        try check(!hasCapability(supportedCLI.replacingOccurrences(of: "let m=d;", with: "await qMt(n);let m=d;")),
                  "unconditional transcript scan after guarded branch fails closed")
        try check(!hasCapability(supportedCLI.replacingOccurrences(of: "behaviors:u", with: "behaviors:transcripts")),
                  "unexpected behavior result fails closed")
        var fragments = ClaudeUsageCapability()
        for fragment in [cliFunction, cliSchema, cliHandler] { fragments.inspect(fragment) }
        try check(fragments.supported, "separate source chunks can appear in any module order")
        let renamed = supportedCLI.replacingOccurrences(of: "Ve", with: "$usage2")
            .replacingOccurrences(of: "Jin", with: "f_3")
            .replacingOccurrences(of: "subtype:R(", with: "subtype:$literal(")
            .replacingOccurrences(of: "skip_behaviors:H()", with: "skip_behaviors:bool()")
        try check(hasCapability(renamed), "safe auto-updates can change minifier identifiers")
    }

    static func testCLIUpdates() throws {
        let project = LocalStore.boundary
        let folder = project.appendingPathComponent(".build/test-work/cli-resolution-\(UUID().uuidString)", isDirectory: true)
        try LocalStore.validate(folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let versions = folder.appendingPathComponent("versions", isDirectory: true)
        try FileManager.default.createDirectory(at: versions, withIntermediateDirectories: false)
        let entry = folder.appendingPathComponent("claude")
        func make(_ version: String, source: String = supportedCLI) throws -> URL {
            let file = versions.appendingPathComponent(version)
            try Data(source.utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            return file
        }
        let first = try make("2.1.287")
        try FileManager.default.createSymbolicLink(at: entry, withDestinationURL: first)
        let fixtureVerifier: (URL) -> Bool = { $0.deletingLastPathComponent() == versions }
        let firstResolved = try ClaudeProvider.resolveCLIURL(entry: entry, versions: versions, signatureVerifier: fixtureVerifier)
        try check(firstResolved == first, "resolve exact native install target")
        let updated = try make("2.1.290")
        try FileManager.default.removeItem(at: entry)
        try FileManager.default.createSymbolicLink(at: entry, withDestinationURL: updated)
        try FileManager.default.removeItem(at: first)
        let updatedResolved = try ClaudeProvider.resolveCLIURL(entry: entry, versions: versions, signatureVerifier: fixtureVerifier)
        try check(updatedResolved == updated, "auto-update and deletion of previous CLI version remains usable")
        func rejected(_ expected: ClaudeProviderError, verifier: (URL) -> Bool = fixtureVerifier) throws {
            do {
                _ = try ClaudeProvider.resolveCLIURL(entry: entry, versions: versions, signatureVerifier: verifier)
                try check(false, "unsafe CLI was accepted")
            } catch let error as ClaudeProviderError {
                try check(error == expected, "expected fail-closed CLI resolution error")
            }
        }
        try rejected(.unsupportedCLI, verifier: { _ in false })
        try rejected(.unsupportedCLI, verifier: { file in
            // A signed install target can change while it is being checked.
            try? Data((supportedCLI + "changed").utf8).write(to: file)
            return true
        })
        try Data(supportedCLI.utf8).write(to: updated)
        try FileManager.default.setAttributes([.posixPermissions: 0o722], ofItemAtPath: updated.path)
        try rejected(.unsupportedCLI)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: updated.path)
        try Data(cliSchema.utf8).write(to: updated)
        try rejected(.unsupportedCLI)
        try Data(supportedCLI.utf8).write(to: updated)
        let escape = folder.appendingPathComponent("2.1.290")
        try Data(supportedCLI.utf8).write(to: escape)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: escape.path)
        try FileManager.default.removeItem(at: entry)
        try FileManager.default.createSymbolicLink(at: entry, withDestinationURL: escape)
        try rejected(.missingCLI)
        try FileManager.default.removeItem(at: entry)
        try FileManager.default.createSymbolicLink(at: entry, withDestinationURL: updated)
        try FileManager.default.removeItem(at: updated)
        try rejected(.missingCLI)
    }

    static func tryDecodeCount(_ value: [String: Any], now: Date) -> Int {
        (try? ClaudeProvider.decode(value, now: now).windows.count) ?? 0
    }

    static func expectDecodeError(_ value: [String: Any], now: Date, expected: ClaudeProviderError) throws {
        do {
            _ = try ClaudeProvider.decode(value, now: now)
            try check(false, "expected decode failure")
        } catch let error as ClaudeProviderError {
            try check(error == expected, "expected normalized decode failure")
        }
    }

    static func assertFailure(_ result: Result<ProviderSnapshot, Error>, is expected: ClaudeProviderError) throws {
        switch result {
        case .success: try check(false, "expected \(expected) failure")
        case .failure(let error):
            try check(error as? ClaudeProviderError == expected, "expected \(expected), got \(error)")
            try check(!error.localizedDescription.contains("PRIVATE_TEST_MARKER"), "private protocol data never displayed")
        }
    }

    static func spin(until condition: () -> Bool, seconds: TimeInterval = 5) {
        let end = Date().addingTimeInterval(seconds)
        while !condition(), Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    }

    static func runMock(_ mode: String, executable: URL, root: URL,
                        timeout: TimeInterval = 2, cancel: Bool = false) throws -> Result<ProviderSnapshot, Error> {
        let provider = ClaudeProvider(executableURL: executable,
                                      arguments: ["--mock-server", mode], timeout: timeout)
        var results: [Result<ProviderSnapshot, Error>] = []
        var onMain = false
        provider.fetch(projectRoot: root) { results.append($0); onMain = Thread.isMainThread }
        if cancel { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { provider.cancel() } }
        spin { !results.isEmpty }
        try check(results.count == 1 && onMain, "\(mode) completes once on main after child cleanup")
        return results[0]
    }

    static func testShutdown(executable: URL, root: URL) throws {
        let folder = root.appendingPathComponent("pids", isDirectory: true)
        try LocalStore.validate(folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let provider = ClaudeProvider(executableURL: executable,
            arguments: ["--mock-server", "hang-reported", folder.path], timeout: 10)
        var results: [Result<ProviderSnapshot, Error>] = []
        func pids() -> [pid_t] {
            ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).compactMap { Int32($0) }
        }
        provider.fetch(projectRoot: root) { results.append($0) }
        spin { pids().count == 1 }
        try check(pids().count == 1, "first child ready")
        provider.fetch(projectRoot: root) { results.append($0) }
        spin { pids().count == 2 }
        try check(pids().count == 2, "superseded and replacement children both tracked")
        let children = pids()
        var shutdowns = 0
        var onMain = false
        provider.shutdown { shutdowns += 1; onMain = Thread.isMainThread }
        spin { shutdowns == 1 }
        try check(shutdowns == 1 && onMain, "shutdown callback on main")
        try check(children.allSatisfy { kill($0, 0) == -1 && errno == ESRCH }, "all children reaped before shutdown callback")
        try check(results.count == 2, "both request completions precede shutdown")
        provider.shutdown { shutdowns += 1 }
        spin { shutdowns == 2 }
        try check(shutdowns == 2, "repeated shutdown completes")
        provider.fetch(projectRoot: root) { results.append($0) }
        spin { results.count == 3 }
        try check(results.count == 3 && pids().count == 2, "post-shutdown fetch starts no process")
        try assertFailure(results[2], is: .cancelled)
    }

    static func request() -> [String: Any]? {
        guard let line = readLine(), let data = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func reply(id: String, response: [String: Any], success: Bool = true) {
        let value: [String: Any] = ["type": "control_response", "response": [
            "subtype": success ? "success" : "error", "request_id": id,
            "response": response, "error": "PRIVATE_TEST_MARKER"
        ]]
        guard var data = try? JSONSerialization.data(withJSONObject: value) else { return }
        data.append(10)
        FileHandle.standardOutput.write(data.prefix(17))
        FileHandle.standardOutput.write(data.dropFirst(17))
    }

    static func mockServer(mode: String) {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let env = ProcessInfo.processInfo.environment
        guard cwd.path.hasPrefix(LocalStore.boundary.path + "/"),
              cwd.path.hasSuffix("/.build/.runtime/claude/workspace"),
              env["CLAUDE_CODE_TMPDIR"] == cwd.deletingLastPathComponent().appendingPathComponent("tmp").path,
              env["TMPDIR"] == env["CLAUDE_CODE_TMPDIR"],
              env["CLAUDE_CODE_DEBUG_LOGS_DIR"]?.hasSuffix("/debug/helper.log") == true,
              env["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] == nil,
              env["DISABLE_UPDATES"] == "1", env["DISABLE_TELEMETRY"] == "1",
              env["DISABLE_ERROR_REPORTING"] == "1", env["ENABLE_CLAUDEAI_MCP_SERVERS"] == "false",
              env["DEBUG"] == nil, env["DEBUG_SDK"] == nil, env["NODE_OPTIONS"] == nil, env["NODE_V8_COVERAGE"] == nil,
              env["BETA_TRACING"] == nil,
              !env.keys.contains(where: { $0.hasPrefix("OTEL_") }) else { return }
        if mode == "hang" || mode == "hang-reported" {
            signal(SIGTERM, SIG_IGN)
            if mode == "hang-reported", CommandLine.arguments.count == 4 {
                let directory = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
                let file = directory.appendingPathComponent(String(getpid()))
                guard (try? LocalStore.validate(file)) != nil, directory.resolvingSymlinksInPath() == directory else { return }
                try? Data().write(to: file)
            }
            while true { sleep(1) }
        }
        if mode == "early-exit" { return }
        guard let first = request(), first.count == 3,
              first["type"] as? String == "control_request",
              let initializeID = first["request_id"] as? String,
              let initialize = first["request"] as? [String: Any], initialize.count == 1,
              initialize["subtype"] as? String == "initialize" else { return }
        if mode == "bad-json" { emit("not json\n"); return }
        if mode == "overflow" { emit(String(repeating: "x", count: 70_000)); while readLine() != nil {}; return }
        if mode == "stderr-overflow" {
            FileHandle.standardError.write(Data(repeating: 120, count: 600_000))
            while readLine() != nil {}; return
        }
        if mode == "unexpected-tool" { emit("{\"type\":\"control_request\",\"request\":{\"subtype\":\"can_use_tool\"}}\n"); return }
        emit("{\"type\":\"system\",\"subtype\":\"init\"}\n")
        for kind in ["keep_alive", "auth_status", "rate_limit_event"] {
            emit("{\"type\":\"\(kind)\",\"output\":\"PRIVATE_TEST_MARKER\"}\n")
        }
        reply(id: "unrelated", response: [:])
        reply(id: initializeID, response: [:], success: mode != "init-error")
        if mode == "init-error" { while readLine() != nil {}; return }
        guard let second = request(), second.count == 3,
              second["type"] as? String == "control_request",
              let usageID = second["request_id"] as? String, usageID != initializeID,
              let usage = second["request"] as? [String: Any], usage.count == 2,
              usage["subtype"] as? String == "get_usage", usage["skip_behaviors"] as? Bool == true else { return }
        var result = payload(now: Date())
        if mode == "behaviors" { result["behaviors"] = ["secret": "PRIVATE_TEST_MARKER"] }
        reply(id: usageID, response: result, success: mode != "usage-error")
        // A prompt, user message, or third control would invalidate this fixture.
        if readLine() != nil { exit(7) }
    }

    static func emit(_ text: String) { FileHandle.standardOutput.write(Data(text.utf8)) }
}
