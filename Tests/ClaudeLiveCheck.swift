// Codex-owned. Manual, permission-gated integration check. Never part of test.sh.
// Does not send a user prompt. Saves only the normalized allowance; prints that
// and fixed protocol/transport/account-status categories, never private identity.
import Foundation
import Darwin

@main
enum ClaudeLiveCheck {
    static func main() {
        let root = LocalStore.boundary
        guard ClaudeProvider.isAuthorized(projectRoot: root) else {
            fputs("Claude live check requires explicit activation approval.\n", stderr)
            exit(2)
        }
        let args = ClaudeProvider.defaultArguments + (CommandLine.arguments.contains("--diagnose-transport") ? ["--debug-to-stderr"] : [])
        let provider = ClaudeProvider(arguments: args, diagnostic: { print($0) })
        provider.fetch(projectRoot: root) { result in
            var code: Int32 = 0
            do {
                var reading = try result.get()
                reading.checkedOnDemand = true
                try LocalStore.write(reading, name: "claude-live-usage.json", root: root)
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .secondsSince1970
                encoder.outputFormatting = [.sortedKeys]
                print(String(decoding: try encoder.encode(reading), as: UTF8.self))
            } catch {
                code = 1
                fputs("Claude live check failed: \(error.localizedDescription)\n", stderr)
            }
            provider.shutdown { exit(code) }
        }
        dispatchMain()
    }
}
