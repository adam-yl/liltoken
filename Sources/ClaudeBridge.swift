// Codex / ChatGPT-owned. Passive, numeric-only Claude Code status-line bridge.
import Foundation

enum ClaudeBridge {
    static let maximumInputBytes = 1_048_576
    private static let maximumCacheBytes = 32_768
    private static let cacheName = "claude-usage.json"

    enum BridgeError: Error, LocalizedError {
        case invalidInput, unsafePath, storageUnavailable
        var errorDescription: String? {
            switch self {
            case .invalidInput: return "Claude status-line input is invalid or too large."
            case .unsafePath: return "Claude usage storage must remain inside the configured checkout without linked cache paths."
            case .storageUnavailable: return "Claude usage storage is unavailable."
            }
        }
    }

    private struct Payload: Decodable {
        let rate_limits: Limits?
    }
    private struct Limits: Decodable {
        let five_hour: Window?
        let seven_day: Window?
    }
    private struct Window: Decodable {
        let used_percentage: Double?
        let resets_at: Double?
    }

    /// Reads documented stdin fields only. No network, credentials, transcripts,
    /// model settings, or Claude configuration are accessed by this method.
    static func consume(input: Data, projectRoot: URL, now: Date = Date()) throws -> String {
        guard input.count <= maximumInputBytes, now.timeIntervalSince1970.isFinite,
              now.timeIntervalSince1970 > 0 else { throw BridgeError.invalidInput }
        let payload: Payload
        do { payload = try JSONDecoder().decode(Payload.self, from: input) }
        catch { throw BridgeError.invalidInput }

        let windows = [
            window(payload.rate_limits?.five_hour, label: "Current session", minutes: 300, now: now),
            window(payload.rate_limits?.seven_day, label: "This week", minutes: 10_080, now: now)
        ].compactMap { $0 }

        // Before the first API response and after a reset, Claude can omit these
        // fields. Keep the previous sample and its original timestamp, never 0%.
        guard !windows.isEmpty else {
            let prior = read(projectRoot: projectRoot, now: now)
            return prior.windows.isEmpty ? "Claude · awaiting usage" : status(prior.windows) + " · cached"
        }
        // Status-line UI events can replay the same API measurements. Preserve
        // the first receipt time for identical windows so an idle session cannot
        // continually make an old measurement look freshly fetched.
        let previous = read(projectRoot: projectRoot, now: now)
        let unchanged = previous.windows.count == windows.count && zip(previous.windows, windows).allSatisfy {
            $0.windowMinutes == $1.windowMinutes && $0.usedPercent == $1.usedPercent && $0.resetsAt == $1.resetsAt
        }
        if unchanged { return status(windows) }
        // Persist only fields present in this response. Combining an old window
        // with a new one would falsely assign the old value a fresh timestamp.
        let snapshot = makeSnapshot(windows: windows, updatedAt: now, message: nil)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(snapshot)
        try LocalStore.writeData(encoded, name: cacheName, root: projectRoot)
        return status(windows)
    }

    static func read(projectRoot: URL, now: Date = Date()) -> ProviderSnapshot {
        let cached: ProviderSnapshot
        do {
            guard let data = LocalStore.readData(cacheName, root: projectRoot) else { return waiting() }
            guard data.count <= maximumCacheBytes else { throw BridgeError.storageUnavailable }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            cached = try decoder.decode(ProviderSnapshot.self, from: data)
        } catch {
            return makeSnapshot(windows: [], updatedAt: nil,
                                message: "Usage cache unavailable. Run a Claude Code prompt to refresh.")
        }

        guard cached.providerID == "claude", let sampled = cached.updatedAt,
              sampled.timeIntervalSince1970.isFinite, sampled.timeIntervalSince1970 > 0,
              now.timeIntervalSince1970.isFinite, sampled <= now.addingTimeInterval(60),
              now.timeIntervalSince(sampled) <= 7 * 86_400 else {
            return makeSnapshot(windows: [], updatedAt: nil,
                                message: "Usage sample is out of date. Run a Claude Code prompt to refresh.")
        }
        var seen = Set<Int>()
        let valid = cached.windows.compactMap { item -> UsageWindow? in
            guard let minutes = item.windowMinutes, [300, 10_080].contains(minutes),
                  seen.insert(minutes).inserted,
                  let reset = item.resetsAt,
                  item.usedPercent.isFinite, (0...100).contains(item.usedPercent),
                  reset.timeIntervalSince1970.isFinite,
                  reset > now, reset <= sampled.addingTimeInterval(Double(minutes * 60) + 300)
            else { return nil }
            return UsageWindow(label: minutes == 300 ? "Current session" : "This week",
                               usedPercent: item.usedPercent, resetsAt: reset, windowMinutes: minutes)
        }.sorted { ($0.windowMinutes ?? 0) < ($1.windowMinutes ?? 0) }

        let message: String
        if valid.isEmpty {
            message = "The saved windows have reset. Run a Claude Code prompt to refresh."
        } else if valid.count < cached.windows.count {
            message = "A saved window has reset. Waiting for a Claude Code update."
        } else if now.timeIntervalSince(sampled) > 15 * 60 {
            message = "Last known usage. Run a Claude Code prompt for a fresh sample."
        } else {
            message = "Updates with Claude Code activity. Desktop use may change usage between updates."
        }
        return makeSnapshot(windows: valid, updatedAt: sampled, message: message)
    }

    /// Keep on-demand and passive reports separate: an idle terminal can replay
    /// older measurements after an on-demand check. It must not overwrite them.
    static func readForDisplay(projectRoot: URL, allowOnDemand: Bool, now: Date = Date()) -> ProviderSnapshot {
        let saved = read(projectRoot: projectRoot, now: now)
        guard allowOnDemand,
              let cached = LocalStore.read("claude-live-usage.json", root: projectRoot),
              cached.providerID == "claude", cached.checkedOnDemand == true,
              let sampled = cached.updatedAt, sampled.timeIntervalSince1970.isFinite,
              sampled.timeIntervalSince1970 > 0, now.timeIntervalSince1970.isFinite,
              sampled <= now.addingTimeInterval(60), now.timeIntervalSince(sampled) <= 7 * 86_400
        else { return saved }
        var seen = Set<Int>()
        let windows = cached.windows.compactMap { item -> UsageWindow? in
            guard let minutes = item.windowMinutes, [300, 10_080].contains(minutes),
                  seen.insert(minutes).inserted, let reset = item.resetsAt,
                  item.usedPercent.isFinite, (0...100).contains(item.usedPercent),
                  reset.timeIntervalSince1970.isFinite,
                  reset > now, reset <= sampled.addingTimeInterval(Double(minutes * 60) + 300)
            else { return nil }
            return UsageWindow(label: minutes == 300 ? "Current session" : "This week",
                               usedPercent: item.usedPercent, resetsAt: reset, windowMinutes: minutes)
        }.sorted { ($0.windowMinutes ?? 0) < ($1.windowMinutes ?? 0) }
        guard !windows.isEmpty else { return saved }
        // A later terminal report that shows strictly greater usage in the same
        // windows is useful even if the next live request fails. Equal or lower
        // replays cannot replace the live reading. Select a whole report; never
        // combine readings with different receipt times.
        let overlaps = saved.windows.compactMap { passive -> (UsageWindow, UsageWindow)? in
            guard let live = windows.first(where: { $0.windowMinutes == passive.windowMinutes }) else { return nil }
            return (passive, live)
        }
        if let received = saved.updatedAt, received > sampled, !overlaps.isEmpty,
           overlaps.allSatisfy({
               guard let savedReset = $0.0.resetsAt, let checkedReset = $0.1.resetsAt else { return false }
               // Statusline epochs use whole seconds; the usage endpoint can
               // include fractions for that same reset (observed live).
               return floor(savedReset.timeIntervalSince1970) == floor(checkedReset.timeIntervalSince1970)
                   && $0.0.usedPercent >= $0.1.usedPercent
           }),
           overlaps.contains(where: { $0.0.usedPercent > $0.1.usedPercent }) {
            return saved
        }
        var snapshot = makeSnapshot(windows: windows, updatedAt: sampled,
                                    message: "Last usage check. Claude may return cached limits.")
        snapshot.checkedOnDemand = true
        return snapshot
    }

    private static func window(_ raw: Window?, label: String, minutes: Int, now: Date) -> UsageWindow? {
        guard let percent = raw?.used_percentage, let epoch = raw?.resets_at,
              percent.isFinite, (0...100).contains(percent), epoch.isFinite else { return nil }
        let reset = Date(timeIntervalSince1970: epoch)
        guard reset > now, reset <= now.addingTimeInterval(Double(minutes * 60) + 300) else { return nil }
        return UsageWindow(label: label, usedPercent: percent, resetsAt: reset, windowMinutes: minutes)
    }

    private static func makeSnapshot(windows: [UsageWindow], updatedAt: Date?, message: String?) -> ProviderSnapshot {
        ProviderSnapshot(providerID: "claude", title: "Claude", subtitle: "Account limits via Claude Code",
                         windows: windows, updatedAt: updatedAt, message: message)
    }
    private static func waiting() -> ProviderSnapshot {
        makeSnapshot(windows: [], updatedAt: nil,
                     message: "Connect Claude Code, then send a prompt to receive usage.")
    }
    private static func status(_ windows: [UsageWindow]) -> String {
        "Claude · " + windows.map {
            let label = $0.windowMinutes == 300 ? "5h" : "week"
            return "\(label) \(Int($0.usedPercent.rounded()))% used"
        }.joined(separator: " · ")
    }

}
