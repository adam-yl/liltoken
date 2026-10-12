// Codex-owned. Experimental Claude Code usage control; never sends a user message.
import Foundation
import CoreFoundation
import Darwin
import Security

enum ClaudeProviderError: LocalizedError, Equatable {
    case notAuthorized, privacyRestricted, missingCLI, unsupportedCLI, invalidResponse, unavailable, timedOut
    case cancelled, outputLimit, launchFailed, unsafeRuntime

    var errorDescription: String? {
        switch self {
        case .notAuthorized: return "Live Claude refresh has not been enabled for Lil Token."
        case .privacyRestricted: return "Claude usage requests are disabled by your existing network privacy setting."
        case .missingCLI: return "The installed Claude Code app is unavailable."
        case .unsupportedCLI: return "This Claude Code update does not have a verified usage-only connection."
        case .invalidResponse: return "Claude Code returned an unsupported usage response."
        case .unavailable: return "Claude usage is unavailable. Check Claude Code sign-in and try again."
        case .timedOut: return "Claude usage took too long to respond. Try refreshing."
        case .cancelled: return "Claude usage refresh was cancelled."
        case .outputLimit: return "Claude Code returned more data than this usage check can accept."
        case .launchFailed: return "The Claude usage helper could not start."
        case .unsafeRuntime: return "The local Claude usage runtime folder is unavailable."
        }
    }
}

/// Uses Claude Code's existing sign-in, including its normal account/runtime writes.
/// A separate, explicit authorization marker is required even if Codex is enabled.
/// Resolve only the native installer entry. Validate its Anthropic signature and
/// inspect the exact target for the usage-only control before launching. Updates
/// can replace the target; unknown implementations fail closed. Never use PATH.
final class ClaudeProvider {
    static let nativeCLIEntry = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/bin/claude")
    static let nativeVersionsDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/share/claude/versions", isDirectory: true)
    private var verifiedSelection: ClaudeCLISelection?
    static let defaultArguments = [
        "--safe-mode", "--print", "--input-format", "stream-json",
        "--output-format", "stream-json", "--verbose", "--no-session-persistence",
        "--tools", "", "--disallowedTools", "mcp__*", "--permission-mode", "dontAsk",
        "--permission-prompts", "none", "--no-chrome", "--strict-mcp-config",
        "--mcp-config", "{\"mcpServers\":{}}", "--settings", "{\"disableAllHooks\":true}"
    ]

    private let queue = DispatchQueue(label: "personal.productivity.lil-token.claude")
    private var requests: [UUID: ClaudeLimitRequest] = [:]
    private var currentRequestID: UUID?
    private var shuttingDown = false
    private var shutdownCallbacks: [() -> Void] = []
    private let executableOverride: URL?
    private let arguments: [String]
    private let timeout: TimeInterval
    private let diagnostic: ((String) -> Void)?

    init(executableURL: URL? = nil, arguments: [String] = ClaudeProvider.defaultArguments,
         timeout: TimeInterval = 15, diagnostic: ((String) -> Void)? = nil) {
        self.executableOverride = executableURL
        self.arguments = arguments
        self.timeout = max(0.1, timeout)
        self.diagnostic = diagnostic
    }

    static func resolvedInstalledCLIURL() throws -> URL {
        try resolveCLIURL(entry: nativeCLIEntry, versions: nativeVersionsDirectory,
                          signatureVerifier: hasAnthropicSignature)
    }

    // Tests use synthetic installer trees and a fixture verifier; production always
    // calls the Apple code-signing verifier against Anthropic's Developer ID.
    static func resolveCLIURL(entry: URL, versions: URL,
                              signatureVerifier: (URL) -> Bool) throws -> URL {
        let candidate = try nativeCLICandidate(entry: entry, versions: versions)
        try verifyCLI(candidate, identity: ClaudeCLIIdentity.read(candidate), signatureVerifier: signatureVerifier)
        return candidate
    }

    private static func nativeCLICandidate(entry: URL, versions: URL) throws -> URL {
        let directory = versions.standardizedFileURL
        let target = entry.standardizedFileURL.resolvingSymlinksInPath()
        guard directory.resolvingSymlinksInPath() == directory,
              target.deletingLastPathComponent() == directory,
              target.lastPathComponent.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil,
              FileManager.default.isExecutableFile(atPath: target.path) else {
            throw ClaudeProviderError.missingCLI
        }
        _ = try ClaudeCLIIdentity.read(target)
        return target
    }

    private static func hasAnthropicSignature(_ url: URL) -> Bool {
        let requirementText = #"identifier "com.anthropic.claude-code" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "Q6L2SF6YDW""#
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess,
              let code, let requirement else { return false }
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures)
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }

    private static func verifyCLI(_ url: URL, identity: ClaudeCLIIdentity,
                                  signatureVerifier: (URL) -> Bool) throws {
        // Signature validation and source decoding can free large temporary
        // allocations that malloc otherwise retains in this long-lived menu app.
        // Ask the documented allocator API to return unused pages after this
        // infrequent validation. It never touches allocated/live objects.
        defer { _ = malloc_zone_pressure_relief(nil, 0) }
        guard autoreleasepool(invoking: { signatureVerifier(url) }) else {
            throw ClaudeProviderError.unsupportedCLI
        }
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) }
        catch { throw ClaudeProviderError.missingCLI }
        defer { try? handle.close() }
        guard try ClaudeCLIIdentity.read(handle.fileDescriptor) == identity else {
            throw ClaudeProviderError.unsupportedCLI
        }
        var capability = ClaudeUsageCapability()
        var overlap = Data()
        // The native executable embeds source. Scan bounded chunks; do not load the
        // 200+ MB executable into the popup's memory or execute a probe that could
        // inspect transcripts. Cache success by inode/size/nanosecond timestamps.
        let sourceMarkers = ["skip_behaviors", "includeBehaviors:", "get_usage:"].map { Data($0.utf8) }
        var total: Int64 = 0
        while true {
            // FileHandle.read bridges through autoreleased NSData. The pool must
            // encompass the read itself so each native-code chunk is released
            // immediately instead of accumulating until the event pool drains.
            let done = try autoreleasepool { () throws -> Bool in
                guard let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty else { return true }
                total += Int64(chunk.count)
                guard total <= identity.size else { throw ClaudeProviderError.unsupportedCLI }
                var window = overlap
                window.append(chunk)
                // Byte search first: almost all native-machine-code chunks contain
                // none of the source markers and need no UTF-16/regex allocation.
                if sourceMarkers.contains(where: { window.range(of: $0) != nil }) {
                    capability.inspect(String(decoding: window, as: UTF8.self))
                }
                overlap = Data(window.suffix(8_192))
                return capability.supported
            }
            if done { break }
        }
        guard capability.supported,
              try ClaudeCLIIdentity.read(handle.fileDescriptor) == identity,
              try ClaudeCLIIdentity.read(url) == identity else {
            throw ClaudeProviderError.unsupportedCLI
        }
    }

    static func isAuthorized(projectRoot: URL) -> Bool {
        LocalStore.readData("claude-live-enabled", root: projectRoot) == Data("approved".utf8)
    }

    // Manual diagnostics emit only these fixed categories, never raw stderr.
    static func diagnosticCategories(in text: String) -> Set<String> {
        var categories = Set<String>()
        if text.contains("fetchUtilization: GET /api/oauth/usage") { categories.insert("request attempted") }
        if text.contains("fetchUtilization: 200 after") { categories.insert("HTTP 200") }
        for status in [401, 403, 429] {
            if text.contains("fetchUtilization: \(status) remembered for this bearer;")
                || text.contains("the endpoint answered \(status) ") { categories.insert("HTTP \(status)") }
        }
        if text.contains("Usage fetch returned a fieldless or non-object body") { categories.insert("unusable response body") }
        if text.contains("[keychain] readAsync failed; not caching a null") { categories.insert("credential store read failed") }
        if text.contains("[keychain] read failed; serving stale cache") { categories.insert("credential store cached fallback") }
        if text.contains("Credentials prime through the store failed (") { categories.insert("credential store priming failed") }
        if text.contains("Failed to load usage data:") {
            categories.insert("usage fetch failed")
            for code in ["ENOTFOUND", "ECONNREFUSED", "ETIMEDOUT", "ECONNRESET", "CERT_HAS_EXPIRED", "UNABLE_TO_GET_ISSUER_CERT_LOCALLY"] {
                if text.contains(code) { categories.insert(code) }
            }
        }
        return categories
    }

    // The SDK's initialization includes account status alongside private identity.
    // Manual diagnostics project only fixed categories; never echo provider values,
    // email, organization, tokens, or the original account object.
    static func accountDiagnosticCategories(in result: [String: Any]) -> [String] {
        guard let account = result["account"] as? [String: Any] else {
            return ["Account: status absent"]
        }
        var categories = ["Account: status present"]
        for (key, label, allowed) in [
            ("subscriptionType", "subscription", ["Claude Pro", "Claude Max", "Claude Team", "Claude Enterprise", "Claude API"]),
            ("apiProvider", "provider", ["firstParty", "bedrock", "vertex", "foundry", "gateway", "mantle", "anthropicAws", "anthropicGoogleCloud"]),
            ("tokenSource", "token source", ["none", "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR",
                                             "CCR_OAUTH_TOKEN_FILE", "ANTHROPIC_AUTH_TOKEN", "profile"]),
            ("apiKeySource", "API key source", ["none", "ANTHROPIC_API_KEY", "apiKeyHelper", "/login managed key"])
        ] {
            let category: String
            if account[key] == nil || account[key] is NSNull { category = "absent" }
            else if let value = account[key] as? String, allowed.contains(value) { category = value }
            else { category = "unrecognized" }
            categories.append("Account: " + label + " " + category)
        }
        return categories
    }

    /// Completion arrives on main only after the exact child has exited and is reaped.
    func fetch(projectRoot: URL, completion: @escaping (Result<ProviderSnapshot, Error>) -> Void) {
        queue.async {
            guard !self.shuttingDown else {
                DispatchQueue.main.async { completion(.failure(ClaudeProviderError.cancelled)) }
                return
            }
            guard Self.isAuthorized(projectRoot: projectRoot) else {
                DispatchQueue.main.async { completion(.failure(ClaudeProviderError.notAuthorized)) }
                return
            }
            if let id = self.currentRequestID {
                self.requests[id]?.stop(with: .failure(ClaudeProviderError.cancelled))
            }
            let executable: URL
            do {
                if let override = self.executableOverride {
                    guard FileManager.default.isExecutableFile(atPath: override.path) else {
                        throw ClaudeProviderError.missingCLI
                    }
                    executable = override // Test helpers only; never selected by installed app.
                } else {
                    let candidate = try Self.nativeCLICandidate(entry: Self.nativeCLIEntry,
                                                              versions: Self.nativeVersionsDirectory)
                    let identity = try ClaudeCLIIdentity.read(candidate)
                    if self.verifiedSelection?.url == candidate, self.verifiedSelection?.identity == identity {
                        executable = candidate
                    } else {
                        try Self.verifyCLI(candidate, identity: identity, signatureVerifier: Self.hasAnthropicSignature)
                        self.verifiedSelection = ClaudeCLISelection(url: candidate, identity: identity)
                        executable = candidate
                    }
                    // Launch the inspected version target, not the moving installer symlink.
                    // A deleted/replaced target fails here; a later refresh resolves the update.
                    guard try ClaudeCLIIdentity.read(candidate) == identity else {
                        throw ClaudeProviderError.unsupportedCLI
                    }
                }
            } catch {
                let error = (error as? ClaudeProviderError) ?? .missingCLI
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            let id = UUID()
            let request = ClaudeLimitRequest(queue: self.queue, executable: executable,
                                            arguments: self.arguments, timeout: self.timeout,
                                            diagnostic: self.diagnostic,
                                            completion: completion, didFinish: { [self] in
                requests[id] = nil
                if currentRequestID == id { currentRequestID = nil }
                finishShutdownIfReady()
            })
            self.requests[id] = request
            self.currentRequestID = id
            request.start(projectRoot: projectRoot)
        }
    }

    func cancel() {
        queue.async {
            if let id = self.currentRequestID {
                self.requests[id]?.stop(with: .failure(ClaudeProviderError.cancelled))
            }
        }
    }

    func shutdown(completion: @escaping () -> Void) {
        queue.async {
            self.shuttingDown = true
            self.shutdownCallbacks.append(completion)
            for request in Array(self.requests.values) {
                request.stop(with: .failure(ClaudeProviderError.cancelled))
            }
            self.finishShutdownIfReady()
        }
    }

    private func finishShutdownIfReady() {
        guard shuttingDown, requests.isEmpty, !shutdownCallbacks.isEmpty else { return }
        let callbacks = shutdownCallbacks
        shutdownCallbacks.removeAll()
        DispatchQueue.main.async { callbacks.forEach { $0() } }
    }

    static func decode(_ result: [String: Any], now: Date = Date()) throws -> ProviderSnapshot {
        guard result["behaviors"] is NSNull else { throw ClaudeProviderError.invalidResponse }
        guard let available = result["rate_limits_available"] as? NSNumber,
              CFGetTypeID(available) == CFBooleanGetTypeID() else {
            throw ClaudeProviderError.invalidResponse
        }
        guard available.boolValue else { throw ClaudeProviderError.unavailable }
        // The CLI explicitly returns null when its account request is unavailable.
        if result["rate_limits"] is NSNull { throw ClaudeProviderError.unavailable }
        guard let limits = result["rate_limits"] as? [String: Any] else {
            throw ClaudeProviderError.invalidResponse
        }
        let dateParser = ISO8601DateFormatter()
        var windows: [UsageWindow] = []
        for (key, label, minutes) in [("five_hour", "Current session", 300), ("seven_day", "This week", 10_080)] {
            guard let item = limits[key], !(item is NSNull) else { continue }
            guard let window = item as? [String: Any],
                  let value = window["utilization"] as? NSNumber,
                  CFGetTypeID(value) != CFBooleanGetTypeID(),
                  value.doubleValue.isFinite, (0...100).contains(value.doubleValue),
                  let text = window["resets_at"] as? String, text.utf8.count <= 64 else { continue }
            dateParser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var reset = dateParser.date(from: text)
            if reset == nil {
                dateParser.formatOptions = [.withInternetDateTime]
                reset = dateParser.date(from: text)
            }
            guard let reset, reset > now,
                  reset <= now.addingTimeInterval(Double(minutes * 60 + 300)) else { continue }
            windows.append(UsageWindow(label: label, usedPercent: value.doubleValue,
                                       resetsAt: reset, windowMinutes: minutes))
        }
        guard !windows.isEmpty else { throw ClaudeProviderError.unavailable }
        // This is when the usage control answered, not a server-generated sample
        // timestamp. The CLI can answer from its cache; the UI must say "Checked".
        return ProviderSnapshot(providerID: "claude", title: "Claude",
                                subtitle: "Account limits via Claude Code", windows: windows,
                                updatedAt: now, message: nil)
    }
}

private struct ClaudeCLISelection {
    let url: URL
    let identity: ClaudeCLIIdentity
}

private struct ClaudeCLIIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
    let size: off_t
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int

    static func read(_ url: URL) throws -> Self {
        var value = stat()
        guard lstat(url.path, &value) == 0 else { throw ClaudeProviderError.missingCLI }
        return try checked(value)
    }

    static func read(_ descriptor: Int32) throws -> Self {
        var value = stat()
        guard fstat(descriptor, &value) == 0 else { throw ClaudeProviderError.missingCLI }
        return try checked(value)
    }

    private static func checked(_ value: stat) throws -> Self {
        guard (value.st_mode & S_IFMT) == S_IFREG, value.st_uid == getuid(),
              value.st_mode & 0o022 == 0,
              value.st_size > 0, value.st_size <= 512 * 1_024 * 1_024 else {
            throw ClaudeProviderError.unsupportedCLI
        }
        return Self(device: value.st_dev, inode: value.st_ino, size: value.st_size,
                    modifiedSeconds: value.st_mtimespec.tv_sec, modifiedNanoseconds: value.st_mtimespec.tv_nsec,
                    changedSeconds: value.st_ctimespec.tv_sec, changedNanoseconds: value.st_ctimespec.tv_nsec)
    }
}

// This conservative recognizer accepts the inspected implementation family,
// independent of minifier names. A schema mention alone is insufficient: the
// installed control must route to a handler that sets includeBehaviors false,
// and that function must short-circuit the scan and return null. New formats
// require review instead of silently enabling a possible transcript scan.
struct ClaudeUsageCapability {
    private var hasSchema = false
    private var handlers: [String: String] = [:]
    private var routedHandlers = Set<String>()
    private var gatedFunctions = Set<String>()
    var supported: Bool {
        hasSchema && handlers.contains { handler, function in
            routedHandlers.contains(handler) && gatedFunctions.contains(function)
        }
    }

    mutating func inspect(_ text: String) {
        let identifier = #"[A-Za-z_$][A-Za-z0-9_$]*"#
        let schema = #"subtype:"# + identifier + #"\("get_usage"\),skip_behaviors:"# + identifier + #"\(\)\.optional\(\)\.describe\("Skip the scan of local transcripts that produces the response's behaviors section \(it is null in the answer\)\."#
        if !Self.matches(schema, in: text).isEmpty { hasSchema = true }
        let handler = "(" + identifier + #")=async\(("# + identifier + #"),("# + identifier + #")\)=>\{if\(\2\.skip_behaviors!=null&&typeof \2\.skip_behaviors!=="boolean"\)throw new "# + identifier + #"\("get_usage: skip_behaviors must be a boolean"\);return\{\.\.\.await ("# + identifier + #")\(\{storageV5:\3\.storageV5,credentials:\3\.credentials,includeBehaviors:!\3\.redactsPersistedLane\(\)&&\2\.skip_behaviors!==!0\}\)\}\}"#
        for groups in Self.matches(handler, in: text) { handlers[groups[1]] = groups[4] }
        for groups in Self.matches(#"(?:\{|,)get_usage:("# + identifier + #")(?:,|\})"#, in: text) {
            routedHandlers.insert(groups[1])
        }
        for groups in Self.matches(Self.implementationPattern, in: text) { gatedFunctions.insert(groups[1]) }
    }

    // Match the entire inspected function structure, allowing only local/minified
    // symbol renaming. Added statements, changed branches, or extra calls require
    // review. In particular, no wildcard can hide an unconditional transcript scan.
    private static let implementationPattern: String = {
        let source = #"async function Jin({includeBehaviors:e=!0,storageV5:n,credentials:o}){let i=mt(),s=i&&_f(),[a,u]=await Promise.all([s?s6n(n,o):Promise.resolve(null),e&&i&&L$e().allowed?qMt(n).then((r)=>({day:g(r.day),week:g(r.week)}),(r)=>(c(r),null)):Promise.resolve(null)]),d=a?.status==="ok"||a?.status==="seeded"?a.utilization:null,p;if(d!==null)try{p=xyt(d.limits,Sse()).map((r)=>({display_name:r.displayName,utilization:r.limit.utilization??null,resets_at:typeof r.limit.resets_at==="number"?new Date(r.limit.resets_at*1000).toISOString():r.limit.resets_at??null}))}catch(r){t(`model_scoped projection failed: ${l(r)}`,{level:"error"})}let m=d;if(d!==null&&a?.status==="seeded"){let{limits:r,...v}=d;m=v}let z=p!==void 0&&a?.status==="ok"&&(a.utilization.five_hour!=null||a.utilization.seven_day!=null)&&Array.isArray(a.utilization.limits)&&!GVo(a.utilization.limits);return{session:{total_cost_usd:Ph(),total_api_duration_ms:HH(),total_duration_ms:qle(),total_lines_added:eAe(),total_lines_removed:tAe(),model_usage:iI()},subscription_type:cr(),rate_limits_available:s,rate_limits:d===null?null:p!==void 0&&p.length>0?{...m,model_scoped:p}:z?{...m,model_scoped:[]}:m,behaviors:u}}"#
        let symbols = Set(["Jin", "e", "n", "o", "i", "s", "a", "u", "d", "p", "r", "m", "z", "v",
                           "mt", "_f", "s6n", "L$e", "qMt", "g", "c", "xyt", "Sse", "t", "l", "GVo",
                           "Ph", "HH", "qle", "eAe", "tAe", "iI", "cr"])
        // Tokenize identifiers and quoted literals so string contents and fixed
        // field names retain their exact meaning while minifier symbols may vary.
        let tokenizer = try! NSRegularExpression(pattern: #""(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`|[A-Za-z_$][A-Za-z0-9_$]*"#)
        let original = source as NSString
        var pattern = "", cursor = 0, groups: [String: Int] = [:]
        for token in tokenizer.matches(in: source, range: NSRange(location: 0, length: original.length)) {
            pattern += NSRegularExpression.escapedPattern(for: original.substring(with: NSRange(location: cursor, length: token.range.location - cursor)))
            let value = original.substring(with: token.range)
            if symbols.contains(value) {
                if let group = groups[value] { pattern += "\\" + String(group) }
                else {
                    groups[value] = groups.count + 1
                    pattern += #"([A-Za-z_$][A-Za-z0-9_$]*)"#
                }
            } else { pattern += NSRegularExpression.escapedPattern(for: value) }
            cursor = token.range.location + token.range.length
        }
        pattern += NSRegularExpression.escapedPattern(for: original.substring(from: cursor))
        return pattern
    }()

    private static func matches(_ pattern: String, in text: String) -> [[String]] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let source = text as NSString
        return expression.matches(in: text, range: NSRange(location: 0, length: source.length)).map { match in
            (0..<match.numberOfRanges).map { index in
                let range = match.range(at: index)
                return range.location == NSNotFound ? "" : source.substring(with: range)
            }
        }
    }
}

private final class ClaudeLimitRequest {
    private let queue: DispatchQueue
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let timeout: TimeInterval
    private let diagnostic: ((String) -> Void)?
    private let initializeID = UUID().uuidString
    private let usageID = UUID().uuidString
    private var completion: ((Result<ProviderSnapshot, Error>) -> Void)?
    private var didFinish: (() -> Void)?
    private var stdoutSource: DispatchSourceRead?
    private var stderrSource: DispatchSourceRead?
    private var timer: DispatchSourceTimer?
    private var killTimer: DispatchSourceTimer?
    private var buffer = Data()
    private var bytesReceived = 0
    private var diagnosticTail = Data()
    private var reportedDiagnostics = Set<String>()
    private var phase = 0
    private var launched = false
    private var exited = false
    private var finished = false
    private var pendingResult: Result<ProviderSnapshot, Error>?
    private let maxOutputBytes = 512 * 1_024
    private let maxLineBytes = 64 * 1_024

    init(queue: DispatchQueue, executable: URL, arguments: [String], timeout: TimeInterval,
         diagnostic: ((String) -> Void)?,
         completion: @escaping (Result<ProviderSnapshot, Error>) -> Void,
         didFinish: @escaping () -> Void) {
        self.queue = queue
        self.timeout = timeout
        self.diagnostic = diagnostic
        self.completion = completion
        self.didFinish = didFinish
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
    }

    func start(projectRoot: URL) {
        do {
            let root = projectRoot.standardizedFileURL
            try LocalStore.validate(root)
            guard root.resolvingSymlinksInPath() == root,
                  ClaudeProvider.isAuthorized(projectRoot: root) else {
                throw ClaudeProviderError.unsafeRuntime
            }
            let inherited = ProcessInfo.processInfo.environment
            if let restriction = inherited["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"],
               !restriction.isEmpty {
                throw ClaudeProviderError.privacyRestricted
            }
            var runtime = root
            for component in [".build", ".runtime", "claude"] {
                runtime.appendPathComponent(component, isDirectory: true)
                try ensureDirectory(runtime)
            }
            var environment = inherited
            // Prevent inherited diagnostics from writing outside the project or
            // sending this helper's runtime details to another collector.
            for key in Array(environment.keys) {
                let upper = key.uppercased()
                if upper == "DEBUG" || upper == "DEBUG_SDK" || upper.contains("BETA_TRACING") || upper.hasPrefix("OTEL_")
                    || upper.hasPrefix("CLAUDE_CODE_OTEL") || upper.hasPrefix("CLAUDE_CODE_DEBUG")
                    || upper == "CLAUDE_CODE_ENABLE_TELEMETRY" || upper == "NODE_OPTIONS"
                    || upper == "NODE_V8_COVERAGE" {
                    environment[key] = nil
                }
            }
            for (key, name) in [("TMPDIR", "tmp"), ("CLAUDE_CODE_TMPDIR", "tmp"),
                                ("XDG_CACHE_HOME", "cache")] {
                let directory = runtime.appendingPathComponent(name, isDirectory: true)
                try ensureDirectory(directory)
                environment[key] = directory.path
            }
            let debug = runtime.appendingPathComponent("debug", isDirectory: true)
            try ensureDirectory(debug)
            let debugLog = debug.appendingPathComponent("helper.log")
            try LocalStore.validate(debugLog)
            environment["CLAUDE_CODE_DEBUG_LOGS_DIR"] = debugLog.path
            environment["DISABLE_UPDATES"] = "1"
            environment["DISABLE_AUTOUPDATER"] = "1"
            environment["DISABLE_TELEMETRY"] = "1"
            environment["DISABLE_ERROR_REPORTING"] = "1"
            // The blanket nonessential-traffic switch also blocks /usage in this
            // CLI. Use the specific controls above and preserve inherited policy.
            environment["ENABLE_CLAUDEAI_MCP_SERVERS"] = "false"
            // Never inspect or redirect HOME, CLAUDE_CONFIG_DIR, or credentials.
            process.environment = environment
            let work = runtime.appendingPathComponent("workspace", isDirectory: true)
            try ensureDirectory(work)
            guard try FileManager.default.contentsOfDirectory(atPath: work.path).isEmpty else {
                throw ClaudeProviderError.unsafeRuntime
            }
            process.currentDirectoryURL = work
            let stdoutFD = output.fileHandleForReading.fileDescriptor
            let stderrFD = errors.fileHandleForReading.fileDescriptor
            _ = fcntl(stdoutFD, F_SETFL, fcntl(stdoutFD, F_GETFL) | O_NONBLOCK)
            _ = fcntl(stderrFD, F_SETFL, fcntl(stderrFD, F_GETFL) | O_NONBLOCK)
            _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            process.terminationHandler = { [self] _ in
                queue.async { [self] in
                    exited = true
                    if pendingResult == nil { drain(fd: stdoutFD, isError: false) }
                    if pendingResult == nil { pendingResult = .failure(ClaudeProviderError.unavailable) }
                    finalize()
                }
            }
            do { try process.run() }
            catch { throw ClaudeProviderError.launchFailed }
            launched = true
            stdoutSource = makeReader(fd: stdoutFD, isError: false)
            stderrSource = makeReader(fd: stderrFD, isError: true)
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + timeout)
            timer.setEventHandler { [self] in stop(with: .failure(ClaudeProviderError.timedOut)) }
            self.timer = timer
            timer.resume()
            try send(["type": "control_request", "request_id": initializeID,
                      "request": ["subtype": "initialize"]])
        } catch {
            stop(with: .failure((error as? ClaudeProviderError) ?? .unsafeRuntime))
        }
    }

    private func ensureDirectory(_ url: URL) throws {
        // Validate all existing ancestors before creation, and reject links/files.
        try LocalStore.validate(url)
        guard url.resolvingSymlinksInPath() == url else { throw ClaudeProviderError.unsafeRuntime }
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw ClaudeProviderError.unsafeRuntime
            }
        } else {
            try fm.createDirectory(at: url, withIntermediateDirectories: false,
                                   attributes: [.posixPermissions: 0o700])
        }
    }

    private func makeReader(fd: Int32, isError: Bool) -> DispatchSourceRead {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [self] in drain(fd: fd, isError: isError) }
        source.resume()
        return source
    }

    private func drain(fd: Int32, isError: Bool) {
        guard !finished, pendingResult == nil else { return }
        var scratch = [UInt8](repeating: 0, count: 8_192)
        while pendingResult == nil {
            let count = Darwin.read(fd, &scratch, scratch.count)
            if count == 0 {
                if isError { stderrSource?.cancel() } else { stdoutSource?.cancel() }
                return
            }
            if count < 0 {
                if errno == EINTR { continue }
                if errno != EAGAIN && errno != EWOULDBLOCK {
                    stop(with: .failure(ClaudeProviderError.unavailable))
                }
                return
            }
            bytesReceived += count
            guard bytesReceived <= maxOutputBytes else {
                stop(with: .failure(ClaudeProviderError.outputLimit)); return
            }
            // Production discards all stderr. A manual check can classify only
            // allowlisted transport outcomes in a bounded, temporary memory tail.
            if isError {
                if let diagnostic {
                    diagnosticTail.append(contentsOf: scratch.prefix(count))
                    let categories = ClaudeProvider.diagnosticCategories(in: String(decoding: diagnosticTail, as: UTF8.self))
                    for category in categories.subtracting(reportedDiagnostics).sorted() { diagnostic("Transport: " + category) }
                    reportedDiagnostics.formUnion(categories)
                    diagnosticTail = Data(diagnosticTail.suffix(2048))
                }
                continue
            }
            buffer.append(contentsOf: scratch.prefix(count))
            while let newline = buffer.firstIndex(of: 10), pendingResult == nil {
                let length = buffer.distance(from: buffer.startIndex, to: newline)
                guard length <= maxLineBytes else {
                    stop(with: .failure(ClaudeProviderError.outputLimit)); return
                }
                let line = Data(buffer.prefix(length))
                buffer.removeFirst(length + 1)
                if !line.isEmpty { receive(line) }
            }
            if buffer.count > maxLineBytes {
                stop(with: .failure(ClaudeProviderError.outputLimit)); return
            }
        }
    }

    private func receive(_ line: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            diagnostic?("Protocol: non-JSON output")
            stop(with: .failure(ClaudeProviderError.invalidResponse)); return
        }
        // Never execute an unexpected tool/permission control request. No prompt
        // was sent, so any assistant/user/tool output is a protocol mismatch.
        guard json["type"] as? String == "control_response" else {
            // Informational SDK events are not usage results. Drop their entire
            // payload (auth_status can contain private diagnostic text).
            if let kind = json["type"] as? String,
               ["system", "keep_alive", "auth_status", "rate_limit_event"].contains(kind) { return }
            // Fixed categories only: never expose arbitrary provider text.
            let kind = json["type"] as? String ?? "other"
            let known = ["keep_alive", "auth_status", "rate_limit_event", "control_request", "assistant", "user", "result", "stream_event"]
            diagnostic?("Protocol: unexpected " + (known.contains(kind) ? kind : "other") + " event")
            stop(with: .failure(ClaudeProviderError.invalidResponse)); return
        }
        guard let envelope = json["response"] as? [String: Any],
              let id = envelope["request_id"] as? String else {
            diagnostic?("Protocol: missing control response envelope")
            stop(with: .failure(ClaudeProviderError.invalidResponse)); return
        }
        guard id == (phase == 0 ? initializeID : usageID) else { return }
        guard envelope["subtype"] as? String == "success",
              let result = envelope["response"] as? [String: Any] else {
            diagnostic?(phase == 0 ? "Protocol: initialization rejected" : "Protocol: usage request rejected")
            stop(with: .failure(ClaudeProviderError.unavailable)); return
        }
        do {
            if phase == 0 {
                diagnostic?("Protocol: initialization accepted")
                if let diagnostic {
                    for category in ClaudeProvider.accountDiagnosticCategories(in: result) { diagnostic(category) }
                }
                phase = 1
                try send(["type": "control_request", "request_id": usageID,
                          "request": ["subtype": "get_usage", "skip_behaviors": true]])
            } else {
                if diagnostic != nil {
                    drain(fd: errors.fileHandleForReading.fileDescriptor, isError: true)
                    guard pendingResult == nil else { return }
                }
                let behaviors = result["behaviors"] is NSNull ? "null" : (result["behaviors"] == nil ? "absent" : "present")
                let rateType = result["rate_limits"] is [String: Any] ? "object" : (result["rate_limits"] is NSNull ? "null" : "absent")
                let available: String
                if let flag = result["rate_limits_available"] as? NSNumber {
                    available = CFGetTypeID(flag) == CFBooleanGetTypeID() ? (flag.boolValue ? "true" : "false") : "non-boolean number"
                } else { available = result["rate_limits_available"] == nil ? "absent" : "non-boolean" }
                diagnostic?("Protocol: usage reply; behaviors " + behaviors + "; rate limits " + rateType + "; available " + available)
                stop(with: .success(try ClaudeProvider.decode(result)))
            }
        } catch {
            stop(with: .failure((error as? ClaudeProviderError) ?? .unavailable))
        }
    }

    private func send(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(10)
        try data.withUnsafeBytes { pointer in
            var offset = 0
            while offset < pointer.count {
                let count = Darwin.write(input.fileHandleForWriting.fileDescriptor,
                                         pointer.baseAddress!.advanced(by: offset), pointer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw ClaudeProviderError.unavailable }
                offset += count
            }
        }
    }

    func stop(with result: Result<ProviderSnapshot, Error>) {
        guard pendingResult == nil, !finished else { return }
        pendingResult = result
        timer?.cancel(); timer = nil
        stdoutSource?.cancel()
        stderrSource?.cancel()
        try? input.fileHandleForWriting.close()
        if !launched || exited { finalize(); return }
        if process.isRunning { process.terminate() }
        let killTimer = DispatchSource.makeTimerSource(queue: queue)
        killTimer.schedule(deadline: .now() + 0.5)
        killTimer.setEventHandler { [self] in
            if !exited, process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        }
        self.killTimer = killTimer
        killTimer.resume()
    }

    private func finalize() {
        guard !finished else { return }
        finished = true
        timer?.cancel(); timer = nil
        killTimer?.cancel(); killTimer = nil
        stdoutSource?.cancel(); stdoutSource = nil
        stderrSource?.cancel(); stderrSource = nil
        process.terminationHandler = nil
        for handle in [input.fileHandleForReading, input.fileHandleForWriting,
                       output.fileHandleForReading, output.fileHandleForWriting,
                       errors.fileHandleForReading, errors.fileHandleForWriting] {
            try? handle.close()
        }
        buffer.removeAll(keepingCapacity: false)
        diagnosticTail.removeAll(keepingCapacity: false)
        let callback = completion
        completion = nil
        let result = pendingResult ?? .failure(ClaudeProviderError.unavailable)
        DispatchQueue.main.async { callback?(result) }
        let onFinish = didFinish
        didFinish = nil
        onFinish?()
    }
}
