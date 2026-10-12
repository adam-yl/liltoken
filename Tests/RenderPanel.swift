import AppKit

@main
enum RenderPanel {
    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        do { try run() }
        catch { fputs("Panel render failed: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    static func run() throws {
        let root = LocalStore.boundary
        let now = Date()
        let scenarios: [(String, [ProviderSnapshot])] = [
            ("connected", [
                ProviderSnapshot(providerID: "claude", title: "Claude", subtitle: "Account limits via Claude Code", windows: [UsageWindow(label: "Current session", usedPercent: 19, resetsAt: now.addingTimeInterval(3600), windowMinutes: 300), UsageWindow(label: "This week", usedPercent: 83, resetsAt: now.addingTimeInterval(86400), windowMinutes: 10080)], updatedAt: now, message: nil),
                ProviderSnapshot(providerID: "codex", title: "ChatGPT / Codex", subtitle: "Codex allowance · ChatGPT account", windows: [UsageWindow(label: "This week", usedPercent: 20, resetsAt: now.addingTimeInterval(86400*5), windowMinutes: 10080)], updatedAt: now, message: nil)
            ]),
            ("waiting", [ClaudeBridge.read(projectRoot: root.appendingPathComponent(".build/test-work/nonexistent")), .codexUnavailable])
        ]
        for (name, snapshots) in scenarios {
            let controller = UsagePanel()
            let content = controller.qaContent(snapshots, footer: "⌥ twice · hover to keep open")
            content.appearance = NSAppearance(named: .aqua)
            let canvas = NSView(frame: content.bounds.insetBy(dx: -12, dy: -12))
            canvas.frame.origin = .zero
            content.frame.origin = NSPoint(x: 12, y: 12)
            canvas.addSubview(content)
            canvas.layoutSubtreeIfNeeded()
            var checks = 0
            func check(_ view: NSView) throws {
                for child in view.subviews {
                    if child is NSTextField || child is NSButton {
                        checks += 1
                        let converted = child.convert(child.bounds, to: content)
                        guard content.bounds.insetBy(dx: -0.5, dy: -0.5).contains(converted) else {
                            throw NSError(domain: "Layout", code: 1, userInfo: [NSLocalizedDescriptionKey: "Control outside card: \(converted)"])
                        }
                    }
                    try check(child)
                }
            }
            try check(content)
            guard let bitmap = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else { throw LocalStoreError.invalidData }
            content.effectiveAppearance.performAsCurrentDrawingAppearance { canvas.cacheDisplay(in: canvas.bounds, to: bitmap) }
            guard let data = bitmap.representation(using: .png, properties: [:]) else { throw LocalStoreError.invalidData }
            let output = root.appendingPathComponent(".build/preview-\(name).png")
            try LocalStore.validate(output)
            try data.write(to: output, options: .atomic)
            print("\(name): \(checks) controls within card; foreground render \(output.path)")
        }
    }
}
