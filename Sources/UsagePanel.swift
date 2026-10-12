import AppKit

private final class HoverSurface: NSView {
    let foreground = TokenGlassContent()
    override init(frame: NSRect) {
        super.init(frame: frame)
        appearance = NSAppearance(named: .aqua)
        wantsLayer = true
        layer?.cornerRadius = TokenTheme.radius
        layer?.masksToBounds = true
        foreground.frame = bounds
        foreground.autoresizingMask = [.width, .height]
        if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            foreground.opaqueFill = true
            addSubview(foreground)
        } else if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: bounds)
            glass.style = .regular
            glass.cornerRadius = TokenTheme.radius
            glass.tintColor = nil
            glass.autoresizingMask = [.width, .height]
            glass.contentView = foreground
            addSubview(glass)
        } else {
            let effect = NSVisualEffectView(frame: bounds)
            effect.material = .popover
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.autoresizingMask = [.width, .height]
            effect.addSubview(foreground)
            addSubview(effect)
        }
    }
    required init?(coder: NSCoder) { nil }
    var hover: ((Bool) -> Void)?
    private var tracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(tracking!)
    }
    override func mouseEntered(with event: NSEvent) { hover?(true) }
    override func mouseExited(with event: NSEvent) { hover?(false) }
}

private final class PassivePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class UsagePanel: NSObject {
    private let projectRoot: URL?

    init(projectRoot: URL? = nil) {
        self.projectRoot = projectRoot
        super.init()
    }

    private var dismissDelay: TimeInterval {
        guard let root = projectRoot,
              let data = LocalStore.readData("popup-delay-seconds", root: root),
              let text = String(data: data, encoding: .utf8),
              let seconds = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              seconds.isFinite, (0.5...60).contains(seconds) else { return 5 }
        return seconds
    }

    #if LIL_TOKEN_QA
    /// Foreground-only QA: native glass needs the live compositor for appearance.
    func qaContent(_ snapshots: [ProviderSnapshot], footer: String) -> NSView {
        let surface = makeContent(snapshots, footer: footer)
        let foreground = surface.foreground
        foreground.removeFromSuperview()
        foreground.opaqueFill = true
        foreground.appearance = NSAppearance(named: .aqua)
        foreground.wantsLayer = true
        foreground.layer?.cornerRadius = TokenTheme.radius
        foreground.layer?.masksToBounds = true
        return foreground
    }
    #endif
    private var panel: NSPanel?
    private var expiry: Timer?
    private var dismissMonitor: Any?
    private var escapeMonitor: Any?
    private var displayTimer: Timer?
    private var allowGlobalInput = false
    private var shownSnapshots: [ProviderSnapshot] = []
    private var shownFooter = ""
    private var generation = 0
    private var dismissing = false
    private let width: CGFloat = 382
    private var refreshAction: (() -> Void)?
    var isVisible: Bool { !dismissing && (panel?.isVisible ?? false) }

    func present(_ snapshots: [ProviderSnapshot], footer: String, allowGlobalInput: Bool, refresh: @escaping () -> Void) {
        refreshAction = refresh
        self.allowGlobalInput = allowGlobalInput
        shownSnapshots = snapshots
        shownFooter = footer
        generation += 1
        let oldFrame = panel?.frame
        let wasVisible = isVisible
        dismissing = false
        let content = makeContent(snapshots, footer: footer)
        let height = content.frame.height
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
        guard let screen else { return }
        let visible = screen.visibleFrame
        let frame = NSRect(x: visible.maxX - width - 16, y: visible.maxY - height - 16, width: width, height: height)
        if panel == nil {
            let window = PassivePanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.appearance = NSAppearance(named: .aqua)
            window.hasShadow = true
            window.level = .floating
            window.hidesOnDeactivate = false
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            window.isMovableByWindowBackground = false
            window.title = "Lil Token usage"
            panel = window
        }
        guard let panel else { return }
        panel.setFrame(wasVisible ? NSRect(x: oldFrame?.minX ?? frame.minX, y: (oldFrame?.maxY ?? frame.maxY) - height, width: width, height: height) : frame, display: true)
        panel.contentView = content
        panel.alphaValue = wasVisible ? 1 : 0
        panel.orderFrontRegardless()
        if !wasVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.18
                panel.animator().alphaValue = 1
            }
        }
        installDismissMonitors()
        // Usage refreshes update the card without extending its visible time.
        if !wasVisible { scheduleDismiss() }
        if displayTimer == nil {
            displayTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.updateVisibleReading() }
            displayTimer?.tolerance = 0.2
        }
    }

    // Only update at changed minute/reset boundaries; no network or cache polling.
    private var lastDisplaySignature = ""
    private func updateVisibleReading() {
        guard let panel, panel.isVisible else { return }
        let signature = shownSnapshots.map { "\($0.freshness())|\($0.displayWindows().count)" }.joined(separator: ";")
        guard signature != lastDisplaySignature else { return }
        lastDisplaySignature = signature
        let content = makeContent(shownSnapshots, footer: shownFooter)
        let old = panel.frame
        panel.setFrame(NSRect(x: old.minX, y: old.maxY - content.frame.height, width: width, height: content.frame.height), display: false)
        panel.contentView = content
        // Preserve the dismissal deadline when redrawing. Hover still pauses it.
    }

    func hide() {
        dismissing = true
        expiry?.invalidate()
        displayTimer?.invalidate()
        displayTimer = nil
        generation += 1
        let expected = generation
        if let dismissMonitor { NSEvent.removeMonitor(dismissMonitor); self.dismissMonitor = nil }
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor); self.escapeMonitor = nil }
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard self?.generation == expected else { return }
            panel.orderOut(nil)
        })
    }

    private func scheduleDismiss() {
        expiry?.invalidate()
        if let panel, panel.frame.contains(NSEvent.mouseLocation) { return }
        expiry = Timer.scheduledTimer(withTimeInterval: dismissDelay, repeats: false) { [weak self] _ in self?.hide() }
    }

    private func installDismissMonitors() {
        guard allowGlobalInput else { return }
        guard dismissMonitor == nil else { return }
        dismissMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in self?.hide() }
        if OptionShortcut.isAuthorized {
            escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                if event.keyCode == 53 { self?.hide() }
            }
        }
    }

    @objc private func closePressed() { hide() }
    @objc private func refreshPressed() { refreshAction?(); scheduleDismiss() }

    private func label(_ text: String, size: CGFloat = 12, weight: NSFont.Weight = .regular, color: NSColor = .labelColor, frame: NSRect, in parent: NSView, help: String? = nil) {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.frame = frame
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        field.toolTip = help ?? text
        parent.addSubview(field)
    }

    private func makeContent(_ snapshots: [ProviderSnapshot], footer: String) -> HoverSurface {
        let rowHeights = snapshots.map { CGFloat(max(1, min(2, $0.displayWindows().count))) * 48 + 70 }
        let height = 62 + rowHeights.reduce(0, +) + 45
        let surface = HoverSurface(frame: NSRect(x: 0, y: 0, width: width, height: height))
        surface.hover = { [weak self] inside in
            if inside { self?.expiry?.invalidate() } else { self?.scheduleDismiss() }
        }
        label("Lil Token", size: 16, weight: .semibold, frame: NSRect(x: 22, y: height - 39, width: 170, height: 23), in: surface.foreground)
        label("YOUR AI ALLOWANCE", size: 9, weight: .medium, color: .secondaryLabelColor, frame: NSRect(x: 22, y: height - 52, width: 230, height: 13), in: surface.foreground)
        let close = TokenButton(title: "×", target: self, action: #selector(closePressed))
        close.closeStyle = true
        close.setAccessibilityLabel("Close usage popup")
        close.isBordered = false
        close.contentTintColor = .secondaryLabelColor
        close.frame = NSRect(x: width - 42, y: height - 43, width: 25, height: 25)
        surface.foreground.addSubview(close)
        var top = height - 62
        for (index, snapshot) in snapshots.enumerated() {
            let tint = TokenTheme.purple
            let dot = NSView(frame: NSRect(x: 22, y: top - 23, width: 9, height: 9))
            dot.wantsLayer = true
            dot.layer?.backgroundColor = tint.cgColor
            dot.layer?.cornerRadius = 4.5
            surface.foreground.addSubview(dot)
            label(snapshot.title, size: 13, weight: .semibold, frame: NSRect(x: 38, y: top - 27, width: width - 65, height: 20), in: surface.foreground)
            label(snapshot.subtitle, size: 10, color: .secondaryLabelColor, frame: NSRect(x: 38, y: top - 41, width: width - 65, height: 15), in: surface.foreground)
            let windows = Array(snapshot.displayWindows().prefix(2))
            var rowTop = top - 50
            if windows.isEmpty {
                label(snapshot.message ?? "Awaiting a fresh usage report.", size: 11, color: .secondaryLabelColor, frame: NSRect(x: 22, y: rowTop - 21, width: width - 44, height: 20), in: surface.foreground)
                rowTop -= 48
            } else {
                for window in windows {
                    label(window.label, size: 11, weight: .medium, frame: NSRect(x: 22, y: rowTop - 15, width: 165, height: 17), in: surface.foreground)
                    let percent = NSTextField(labelWithString: "\(Int(window.usedPercent.rounded()))% used")
                    percent.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
                    percent.alignment = .right
                    percent.frame = NSRect(x: width - 120, y: rowTop - 15, width: 98, height: 17)
                    surface.foreground.addSubview(percent)
                    let track = NSView(frame: NSRect(x: 22, y: rowTop - 26, width: width - 44, height: 5))
                    track.wantsLayer = true
                    track.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
                    track.layer?.cornerRadius = 2.5
                    let fill = CALayer()
                    fill.frame = CGRect(x: 0, y: 0, width: (width - 44) * min(100, max(0, window.usedPercent)) / 100, height: 5)
                    fill.cornerRadius = 2.5
                    fill.backgroundColor = (window.usedPercent >= 90 ? NSColor.systemRed : window.usedPercent >= 75 ? NSColor.systemOrange : tint).cgColor
                    track.layer?.addSublayer(fill)
                    track.setAccessibilityElement(true)
                    track.setAccessibilityLabel("\(window.label), \(Int(window.usedPercent)) percent used")
                    surface.foreground.addSubview(track)
                    let reset: String
                    if let date = window.resetsAt {
                        let formatter = DateFormatter()
                        formatter.dateFormat = Calendar.current.isDateInToday(date) ? "h:mm a" : "EEE h:mm a"
                        reset = "Resets \(formatter.string(from: date))"
                    } else { reset = "Reset time unavailable" }
                    label(reset, size: 10, color: .secondaryLabelColor, frame: NSRect(x: 22, y: rowTop - 43, width: width - 44, height: 14), in: surface.foreground)
                    rowTop -= 48
                }
            }
            label(snapshot.freshness(), size: 9, color: .tertiaryLabelColor, frame: NSRect(x: 22, y: rowTop - 12, width: width - 44, height: 13), in: surface.foreground, help: snapshot.message)
            top -= rowHeights[index]
            let separator = NSBox(frame: NSRect(x: 22, y: top, width: width - 44, height: 1))
            separator.boxType = .separator
            surface.foreground.addSubview(separator)
        }
        label(footer, size: 10, color: .secondaryLabelColor, frame: NSRect(x: 22, y: 15, width: width - 145, height: 17), in: surface.foreground)
        let refresh = TokenButton(title: "↻ Refresh", target: self, action: #selector(refreshPressed))
        refresh.primary = true
        refresh.isBordered = false
        refresh.setAccessibilityLabel("Refresh usage")
        refresh.bezelStyle = .inline
        refresh.font = .systemFont(ofSize: 11, weight: .medium)
        refresh.frame = NSRect(x: width - 108, y: 9, width: 86, height: 29)
        surface.foreground.addSubview(refresh)
        return surface
    }
}
