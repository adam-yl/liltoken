// Codex-owned. Reads subscription limits only; never starts a thread or turn.
import Foundation
import CoreFoundation
import Darwin

enum CodexProviderError: LocalizedError, Equatable {
    case missingCLI, invalidResponse, unavailable, timedOut, cancelled, outputLimit, launchFailed, unsafeRuntime

    var errorDescription: String? {
        switch self {
        case .missingCLI: return "The bundled Codex command could not be found."
        case .invalidResponse: return "Codex returned an unsupported usage response."
        case .unavailable: return "Codex usage is unavailable. Check your Codex sign-in and try again."
        case .timedOut: return "Codex usage took too long to respond. Try refreshing."
        case .cancelled: return "Codex usage refresh was cancelled."
        case .outputLimit: return "Codex returned more data than this usage check can accept."
        case .launchFailed: return "The Codex usage helper could not start."
        case .unsafeRuntime: return "The local usage runtime folder is unavailable."
        }
    }
}

/// Calling fetch starts a short-lived app-server using the existing Codex sign-in.
/// The app must gate live activation on authorization for Codex's own runtime writes.
/// The helper never reads credentials, changes settings, or invokes inference APIs.
final class CodexProvider {
    private let queue = DispatchQueue(label: "personal.productivity.lil-token.codex")
    private var requests: [UUID: CodexLimitRequest] = [:]
    private var currentRequestID: UUID?
    private var shuttingDown = false
    private var shutdownCallbacks: [() -> Void] = []
    private let executableOverride: URL?
    private let arguments: [String]
    private let timeout: TimeInterval

    init(executableURL: URL? = nil, arguments: [String] = ["app-server"], timeout: TimeInterval = 15) {
        self.executableOverride = executableURL
        self.arguments = arguments
        self.timeout = max(0.1, timeout)
    }

    /// Completion is delivered on the main queue, after the child has exited.
    func fetch(projectRoot: URL, completion: @escaping (Result<ProviderSnapshot, Error>) -> Void) {
        queue.async {
            guard !self.shuttingDown else {
                DispatchQueue.main.async { completion(.failure(CodexProviderError.cancelled)) }
                return
            }
            if let id = self.currentRequestID {
                self.requests[id]?.stop(with: .failure(CodexProviderError.cancelled))
            }
            guard let executable = self.executableOverride ?? Self.locateCLI() else {
                DispatchQueue.main.async { completion(.failure(CodexProviderError.missingCLI)) }
                return
            }
            let id = UUID()
            let request = CodexLimitRequest(queue: self.queue, executable: executable,
                                           arguments: self.arguments, timeout: self.timeout,
                                           completion: completion, didFinish: { [self] in
                self.requests[id] = nil
                if self.currentRequestID == id { self.currentRequestID = nil }
                self.finishShutdownIfReady()
            })
            self.requests[id] = request
            self.currentRequestID = id
            request.start(projectRoot: projectRoot)
        }
    }

    func cancel() {
        queue.async {
            if let id = self.currentRequestID {
                self.requests[id]?.stop(with: .failure(CodexProviderError.cancelled))
            }
        }
    }

    /// Permanently rejects new fetches and completes on main after every child,
    /// including superseded requests still shutting down, has exited and been reaped.
    func shutdown(completion: @escaping () -> Void) {
        queue.async {
            self.shuttingDown = true
            self.shutdownCallbacks.append(completion)
            for request in Array(self.requests.values) {
                request.stop(with: .failure(CodexProviderError.cancelled))
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

    private static func locateCLI() -> URL? {
        // Explicit app-bundle paths avoid running arbitrary programs from PATH.
        let paths = [
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
        ]
        return paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
            .map { URL(fileURLWithPath: $0) }
    }

    static func decode(_ result: [String: Any], now: Date = Date()) throws -> ProviderSnapshot {
        let map = result["rateLimitsByLimitId"] as? [String: Any]
        let legacy = result["rateLimits"] as? [String: Any]
        // Never substitute a different model/service bucket for the Codex allowance.
        let bucket = (map?["codex"] as? [String: Any]) ?? legacy.flatMap { value in
            let limitID = value["limitId"] as? String
            return limitID == nil || limitID == "codex" ? value : nil
        }
        guard result.keys.contains("rateLimits") || result.keys.contains("rateLimitsByLimitId") else {
            throw CodexProviderError.invalidResponse
        }
        var windows: [UsageWindow] = []
        for (key, fallback) in [("primary", "Primary window"), ("secondary", "Secondary window")] {
            guard let raw = bucket?[key] as? [String: Any],
                  let used = number(raw["usedPercent"]), used.isFinite else { continue }
            let rawMinutes = number(raw["windowDurationMins"])
            let minutes: Int? = rawMinutes.flatMap {
                $0.isFinite && $0 > 0 && $0 <= 525_600 && $0.rounded() == $0 ? Int($0) : nil
            }
            let reset = number(raw["resetsAt"]).flatMap { value -> Date? in
                guard value.isFinite, value > 0, value < 253_402_300_800 else { return nil }
                return Date(timeIntervalSince1970: value)
            }
            windows.append(UsageWindow(label: label(minutes: minutes, fallback: fallback),
                                       usedPercent: min(100, max(0, used)), resetsAt: reset,
                                       windowMinutes: minutes))
        }
        return ProviderSnapshot(providerID: "codex", title: "ChatGPT / Codex",
                                subtitle: "Codex allowance · ChatGPT account", windows: windows,
                                updatedAt: now,
                                message: windows.isEmpty ? "Codex did not return percentage-based usage limits." : nil)
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue
    }

    private static func label(minutes: Int?, fallback: String) -> String {
        switch minutes {
        case 10_080: return "This week"
        case 300: return "Current session"
        case 1_440: return "Daily window"
        case .some(let value) where value % 1_440 == 0: return "\(value / 1_440)-day window"
        case .some(let value) where value % 60 == 0: return "\(value / 60)-hour window"
        case .some(let value): return "\(value)-minute window"
        case .none: return fallback
        }
    }
}

private final class CodexLimitRequest {
    private let queue: DispatchQueue
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let timeout: TimeInterval
    private var completion: ((Result<ProviderSnapshot, Error>) -> Void)?
    private var didFinish: (() -> Void)?
    private var stdoutSource: DispatchSourceRead?
    private var stderrSource: DispatchSourceRead?
    private var timer: DispatchSourceTimer?
    private var killTimer: DispatchSourceTimer?
    private var buffer = Data()
    private var bytesReceived = 0
    private var phase = 0
    private var launched = false
    private var exited = false
    private var finished = false
    private var pendingResult: Result<ProviderSnapshot, Error>?
    private let maxOutputBytes = 512 * 1_024
    private let maxLineBytes = 64 * 1_024

    init(queue: DispatchQueue, executable: URL, arguments: [String], timeout: TimeInterval,
         completion: @escaping (Result<ProviderSnapshot, Error>) -> Void,
         didFinish: @escaping () -> Void) {
        self.queue = queue
        self.timeout = timeout
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
            guard root.resolvingSymlinksInPath() == root else { throw CodexProviderError.unsafeRuntime }
            var runtime = root
            for component in [".build", ".runtime", "codex"] {
                runtime.appendPathComponent(component, isDirectory: true)
                try ensureDirectory(runtime, within: root)
            }
            var environment = ProcessInfo.processInfo.environment
            for (key, name) in [("TMPDIR", "tmp"), ("XDG_CACHE_HOME", "cache")] {
                let directory = runtime.appendingPathComponent(name, isDirectory: true)
                try ensureDirectory(directory, within: root)
                environment[key] = directory.path
            }
            // Do not copy, inspect, or override HOME/CODEX_HOME or authentication.
            process.environment = environment
            process.currentDirectoryURL = root
            let stdoutFD = output.fileHandleForReading.fileDescriptor
            let stderrFD = errors.fileHandleForReading.fileDescriptor
            _ = fcntl(stdoutFD, F_SETFL, fcntl(stdoutFD, F_GETFL) | O_NONBLOCK)
            _ = fcntl(stderrFD, F_SETFL, fcntl(stderrFD, F_GETFL) | O_NONBLOCK)
            _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            process.terminationHandler = { [self] _ in
                queue.async { [self] in
                    exited = true
                    if pendingResult == nil { drain(fd: stdoutFD, isError: false) }
                    if pendingResult == nil { pendingResult = .failure(CodexProviderError.unavailable) }
                    finalize()
                }
            }
            try process.run()
            launched = true
            stdoutSource = makeReader(fd: stdoutFD, isError: false)
            stderrSource = makeReader(fd: stderrFD, isError: true)
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + timeout)
            timer.setEventHandler { [self] in stop(with: .failure(CodexProviderError.timedOut)) }
            self.timer = timer
            timer.resume()
            try send(["method": "initialize", "id": 1, "params": ["clientInfo": [
                "name": "lil_token", "title": "Lil Token", "version": "0.1.0"
            ]]])
        } catch {
            stop(with: .failure((error as? CodexProviderError) ?? CodexProviderError.launchFailed))
        }
    }

    private func ensureDirectory(_ url: URL, within root: URL) throws {
        guard url.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else {
            throw CodexProviderError.unsafeRuntime
        }
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw CodexProviderError.unsafeRuntime
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
                    stop(with: .failure(CodexProviderError.unavailable))
                }
                return
            }
            bytesReceived += count
            guard bytesReceived <= maxOutputBytes else {
                stop(with: .failure(CodexProviderError.outputLimit)); return
            }
            // Drain stderr but never retain or display it: it may contain private context.
            if isError { continue }
            buffer.append(contentsOf: scratch.prefix(count))
            while let newline = buffer.firstIndex(of: 10), pendingResult == nil {
                let length = buffer.distance(from: buffer.startIndex, to: newline)
                guard length <= maxLineBytes else {
                    stop(with: .failure(CodexProviderError.outputLimit)); return
                }
                let line = Data(buffer.prefix(length))
                buffer.removeFirst(length + 1)
                if !line.isEmpty { receive(line) }
            }
            if buffer.count > maxLineBytes {
                stop(with: .failure(CodexProviderError.outputLimit)); return
            }
        }
    }

    private func receive(_ line: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            stop(with: .failure(CodexProviderError.invalidResponse)); return
        }
        guard let id = json["id"] as? Int, id == (phase == 0 ? 1 : 2) else { return }
        guard json["error"] == nil, let result = json["result"] as? [String: Any] else {
            stop(with: .failure(CodexProviderError.unavailable)); return
        }
        do {
            if phase == 0 {
                phase = 1
                try send(["method": "initialized", "params": [:]])
                try send(["method": "account/rateLimits/read", "id": 2])
            } else {
                stop(with: .success(try CodexProvider.decode(result)))
            }
        } catch {
            stop(with: .failure((error as? CodexProviderError) ?? CodexProviderError.unavailable))
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
                guard count > 0 else { throw CodexProviderError.unavailable }
                offset += count
            }
        }
    }

    func stop(with result: Result<ProviderSnapshot, Error>) {
        guard pendingResult == nil, !finished else { return }
        pendingResult = result
        timer?.cancel()
        timer = nil
        stdoutSource?.cancel()
        stderrSource?.cancel()
        try? input.fileHandleForWriting.close()
        if !launched || exited { finalize(); return }
        if process.isRunning { process.terminate() }
        // A misbehaving child cannot survive cancellation indefinitely. Foundation
        // reaps this exact Process and calls terminationHandler before completion.
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
        let callback = completion
        completion = nil
        let result = pendingResult ?? .failure(CodexProviderError.unavailable)
        DispatchQueue.main.async { callback?(result) }
        let onFinish = didFinish
        didFinish = nil
        onFinish?()
    }
}
