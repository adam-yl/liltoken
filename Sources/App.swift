import AppKit

final class LilTokenApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let root: URL
    private let live: Bool
    private var statusItem: NSStatusItem!
    private let popup: UsagePanel
    private let shortcut = OptionShortcut()
    private let codex = CodexProvider()
    private let claude = ClaudeProvider()
    private var snapshots: [ProviderSnapshot] = []
    private var refreshing = false
    private var lastAttempt = Date.distantPast
    private var footer = ""
    private var refreshFailures: [String: String] = [:]
    private var permissionItem: NSMenuItem!
    private var shuttingDown = false
    private var lastRuntimeHealth: Data?
    private var shortcutRecoveryObservers: [NSObjectProtocol] = []

    init(root: URL, live: Bool) {
        self.root = root
        self.live = live
        self.popup = UsagePanel(projectRoot: root)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "chart.bar.xaxis", accessibilityDescription: "Lil Token")
        statusItem.button?.toolTip = "Lil Token · double-tap Option for AI usage"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        shortcut.onStateChanged = { [weak self] in self?.recordRuntimeHealth() }
        reloadCaches()
        updateShortcut()
        installShortcutRecovery()
        NotificationCenter.default.addObserver(self, selector: #selector(recheckPermission), name: NSApplication.didBecomeActiveNotification, object: nil)
        // Login launches stay quiet. Usage is checked when the popup opens.
        // Registration is changed only by an explicit command/menu action.
        if CommandLine.arguments.contains("--show") { showUsage() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        shuttingDown = true
        for observer in shortcutRecoveryObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        shortcutRecoveryObservers.removeAll()
        shortcut.stop()
        popup.hide()
        let pending = DispatchGroup()
        pending.enter()
        codex.shutdown { pending.leave() }
        pending.enter()
        claude.shutdown { pending.leave() }
        pending.notify(queue: .main) { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    @objc private func recheckPermission() { updateShortcut() }

    private func updateShortcut(forceRestart: Bool = false) {
        if live { _ = shortcut.start(forceRestart: forceRestart) { [weak self] in self?.toggle() } }
        recordRuntimeHealth()
    }

    private func installShortcutRecovery() {
        guard live else { return }
        // Keep these observers even if initial login trust is not ready. No
        // application/window contents or notification payloads are inspected.
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification,
                     NSWorkspace.didActivateApplicationNotification] {
            shortcutRecoveryObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in self?.recoverMissingShortcut() })
        }
        // A bounded login retry, not an ongoing timer or account poll.
        for delay in [0.5, 2.0, 5.0, 10.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.recoverMissingShortcut() }
        }
    }

    private func recoverMissingShortcut() {
        guard !shuttingDown, !shortcut.isMonitoring else { return }
        updateShortcut()
    }

    private func recordRuntimeHealth() {
        // Configuration status from this GUI process, never input events, text,
        // key identities, held-key counts, or shortcut timestamps/history.
        let fields: [String: Any] = [
            "schema": 1,
            "pid": ProcessInfo.processInfo.processIdentifier,
            "running": !shuttingDown,
            "live": live,
            "accessibilityEnabled": OptionShortcut.isAuthorized,
            "shortcutMonitoring": shortcut.isMonitoring,
            "secureInputActive": OptionShortcut.isSecureInputActive,
            "launchAtLoginEnabled": LoginStartup.isEnabled
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
              data != lastRuntimeHealth else { return }
        do {
            try LocalStore.writeData(data, name: "app-health.json", root: root)
            lastRuntimeHealth = data
        } catch { /* Optional local diagnostics never block the app. */ }
    }

    @objc private func statusClicked() {
        updateShortcut(forceRestart: true)
        if NSApp.currentEvent?.type == .rightMouseUp { showMenu() }
        else { toggle() }
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.delegate = self
        let show = menu.addItem(withTitle: "Show usage", action: #selector(showUsage), keyEquivalent: "")
        show.target = self
        let authorized = OptionShortcut.isAuthorized
        let shortcutTitle: String
        let shortcutAction: Selector?
        if !live { shortcutTitle = "Live connections await setup"; shortcutAction = nil }
        else if !authorized { shortcutTitle = "Enable double-Option shortcut…"; shortcutAction = #selector(openShortcutSettings) }
        else if !shortcut.isMonitoring { shortcutTitle = "Reconnect double-Option shortcut"; shortcutAction = #selector(reconnectShortcut) }
        else { shortcutTitle = "Double-Option shortcut enabled"; shortcutAction = nil }
        permissionItem = menu.addItem(withTitle: shortcutTitle, action: shortcutAction, keyEquivalent: "")
        permissionItem.target = self
        let startup = menu.addItem(withTitle: LoginStartup.needsApproval ? "Allow launch at login…" : "Launch at login", action: #selector(toggleLoginStartup), keyEquivalent: "")
        startup.target = self
        startup.state = LoginStartup.isEnabled ? .on : .off
        let details = menu.addItem(withTitle: "How Lil Token reads usage…", action: #selector(openReadme), keyEquivalent: "")
        details.target = self
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "Quit Lil Token", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
    }

    func menuDidClose(_ menu: NSMenu) { statusItem.menu = nil }
    @objc private func quitApp() { NSApp.terminate(nil) }
    @objc private func reconnectShortcut() { updateShortcut(forceRestart: true) }
    @objc private func openReadme() { NSWorkspace.shared.open(root.appendingPathComponent("README.md")) }

    @objc private func toggleLoginStartup() {
        defer { recordRuntimeHealth() }
        if LoginStartup.needsApproval { LoginStartup.openSettings(); return }
        do {
            if LoginStartup.isEnabled { try LoginStartup.disable() }
            else { try LoginStartup.enable() }
            if LoginStartup.needsApproval { LoginStartup.openSettings() }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Lil Token couldn’t change launch at login"
            alert.informativeText = "Check Lil Token in System Settings → General → Login Items & Extensions."
            alert.addButton(withTitle: "Open Login Items")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn { LoginStartup.openSettings() }
        }
    }

    @objc private func openShortcutSettings() {
        // This only opens when the user explicitly selects the setup menu action.
        let alert = NSAlert()
        alert.messageText = "Enable Lil Token’s keyboard shortcut"
        alert.informativeText = "Allow Lil Token in Accessibility to detect two Option taps. It does not record what you type. After enabling it, click Lil Token’s menu-bar icon to recheck access."
        alert.addButton(withTitle: "Open Accessibility")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func toggle() { if popup.isVisible { popup.hide() } else { showUsage() } }

    private func reloadCaches() {
        let claude = ClaudeBridge.readForDisplay(projectRoot: root,
                                                allowOnDemand: live && ClaudeProvider.isAuthorized(projectRoot: root))
        let openai = LocalStore.read("codex-usage.json", root: root) ?? .codexUnavailable
        snapshots = [claude, openai]
    }

    @objc private func showUsage() {
        reloadCaches()
        if !live { footer = "Setup pending · saved readings" }
        else if !OptionShortcut.isAuthorized { footer = "Shortcut needs Accessibility" }
        else if OptionShortcut.isSecureInputActive { footer = "Shortcut paused for secure input" }
        else if !shortcut.isMonitoring { footer = "Click chart to reconnect shortcut" }
        else { footer = "⌥ twice · hover to keep open" }
        if !refreshFailures.isEmpty {
            footer = refreshFailures.keys.sorted().compactMap { refreshFailures[$0] }.joined(separator: " · ")
        }
        render()
        refreshUsage(force: false)
    }

    private func render() {
        popup.present(snapshots, footer: footer, allowGlobalInput: live) { [weak self] in self?.refreshUsage(force: true) }
    }

    private func refreshUsage(force: Bool) {
        reloadCaches()
        guard live else { footer = "Setup pending · saved readings only"; if popup.isVisible { render() }; return }
        guard !refreshing else { if popup.isVisible { render() }; return }
        guard Date().timeIntervalSince(lastAttempt) >= (force ? 5 : 60) else { if popup.isVisible { render() }; return }
        refreshing = true
        lastAttempt = Date()
        let checkClaude = ClaudeProvider.isAuthorized(projectRoot: root)
        footer = checkClaude ? "Checking Claude and Codex…" : "Refreshing Codex…"
        if popup.isVisible { render() }
        var remaining = checkClaude ? 2 : 1
        var outcomes: [String: String] = [:]
        // Both providers deliver on main, after reaping their child processes.
        let completed: (String, Result<ProviderSnapshot, Error>) -> Void = { [weak self] provider, result in
            guard let self, !self.shuttingDown else { return }
            switch result {
            case .success(var reading):
                do {
                    if provider == "claude" { reading.checkedOnDemand = true }
                    let file = provider == "claude" ? "claude-live-usage.json" : "codex-usage.json"
                    try LocalStore.write(reading, name: file, root: self.root)
                    self.refreshFailures[provider] = nil
                    outcomes[provider] = provider == "claude" ? "Claude checked" : "Codex updated"
                } catch {
                    let failure = provider == "claude" ? "Claude save failed" : "Codex save failed"
                    self.refreshFailures[provider] = failure
                    outcomes[provider] = failure
                }
            case .failure(let error):
                // Never stamp a failed request onto the retained reading.
                let failure = provider == "claude" ? Self.claudeFailureText(error) : "Codex unavailable"
                self.refreshFailures[provider] = failure
                outcomes[provider] = failure
            }
            remaining -= 1
            self.refreshing = remaining > 0
            self.reloadCaches()
            self.footer = [checkClaude ? (outcomes["claude"] ?? "Checking Claude…") : "Claude saved report",
                           outcomes["codex"] ?? "Checking Codex…"].joined(separator: " · ")
            if self.popup.isVisible { self.render() }
        }
        codex.fetch(projectRoot: root) { completed("codex", $0) }
        if checkClaude { claude.fetch(projectRoot: root) { completed("claude", $0) } }
    }

    private static func claudeFailureText(_ error: Error) -> String {
        guard let error = error as? ClaudeProviderError else { return "Claude unavailable" }
        switch error {
        case .missingCLI: return "Claude Code needs setup"
        case .unsupportedCLI: return "Claude update needs support"
        case .privacyRestricted: return "Claude blocked by privacy setting"
        case .timedOut: return "Claude timed out · retry Refresh"
        default: return "Claude unavailable · saved reading"
        }
    }
}

@main
enum Main {
    static func main() {
        let args = CommandLine.arguments
        let suppliedRoot = args.firstIndex(of: "--project-root").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        let rootPath = suppliedRoot ?? Bundle.main.object(forInfoDictionaryKey: "LilTokenProjectRoot") as? String
        guard let rootPath else { fputs("Lil Token: project location unavailable.\n", stderr); exit(1) }
        let root = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL
        guard (try? LocalStore.validate(root)) != nil else { fputs("Lil Token: project must remain inside its configured checkout without linked paths.\n", stderr); exit(1) }
        if args.contains("--claude-statusline") {
            do {
                var data = Data()
                while let chunk = try FileHandle.standardInput.read(upToCount: min(65_536, 1_048_577 - data.count)), !chunk.isEmpty {
                    data.append(chunk)
                    guard data.count <= 1_048_576 else { throw LocalStoreError.invalidData }
                }
                let text = try ClaudeBridge.consume(input: data, projectRoot: root)
                print(text)
                exit(0)
            } catch { print("Claude · usage unavailable"); exit(0) }
        }
        // These commands belong to this exact app bundle. Status is read-only;
        // registration requires explicit permission for OS-managed login state.
        if args.contains("--startup-status") {
            print("Launch at login: \(LoginStartup.statusText)")
            print("Accessibility (this process): \(OptionShortcut.isAuthorized ? "enabled" : "not enabled")")
            print("GUI shortcut status: project .runtime/app-health.json (match its pid to the running app)")
            exit(0)
        }
        if args.contains("--enable-login") {
            do {
                try LoginStartup.enable()
                print("Launch at login: \(LoginStartup.statusText)")
                exit(LoginStartup.isEnabled ? 0 : 2)
            } catch {
                fputs("Lil Token: could not register launch at login. Check Login Items in System Settings.\n", stderr)
                exit(1)
            }
        }
        let activation = LocalStore.readData("live-enabled", root: root).flatMap { String(data: $0, encoding: .utf8) }
        let live = args.contains("--live") || activation?.trimmingCharacters(in: .whitespacesAndNewlines) == "approved"
        let app = NSApplication.shared
        let delegate = LilTokenApp(root: root, live: live)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
