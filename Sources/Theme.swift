import AppKit

// Shared light-gray glass and light-purple action palette.
enum TokenTheme {
    static let purple = NSColor(srgbRed: 138/255, green: 101/255, blue: 196/255, alpha: 1)
    static let gray = NSColor(srgbRed: 233/255, green: 233/255, blue: 233/255, alpha: 1)
    static let darkPurple = NSColor(srgbRed: 93/255, green: 74/255, blue: 130/255, alpha: 1)
    static let lightPurple = NSColor(srgbRed: 217/255, green: 182/255, blue: 252/255, alpha: 1)
    static let actionText = darkPurple.blended(withFraction: 0.06, of: .black)!
    static let radius: CGFloat = 21
}

final class TokenGlassContent: NSView {
    var opaqueFill = false
    override var isOpaque: Bool { opaqueFill }
    override func draw(_ dirtyRect: NSRect) {
        TokenTheme.gray.withAlphaComponent(opaqueFill ? 1 : 0.25).setFill()
        NSBezierPath(rect: bounds).fill()
    }
}

final class TokenButton: NSButton {
    var primary = false
    var closeStyle = false
    private var hovering = false
    private var tracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(tracking!)
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        let pressed = cell?.isHighlighted ?? false
        let fill: NSColor
        if primary {
            fill = pressed ? TokenTheme.lightPurple.blended(withFraction: 0.045, of: TokenTheme.darkPurple)! : hovering ? TokenTheme.lightPurple.blended(withFraction: 0.08, of: .white)! : TokenTheme.lightPurple
        } else {
            fill = NSColor.labelColor.withAlphaComponent(pressed ? 0.15 : hovering ? 0.09 : closeStyle ? 0 : 0.045)
        }
        fill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: closeStyle ? 7 : 9.6, yRadius: closeStyle ? 7 : 9.6).fill()
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: closeStyle ? 13 : 11, weight: .semibold), .foregroundColor: primary ? TokenTheme.actionText : NSColor.labelColor, .paragraphStyle: paragraph]
        let text = NSAttributedString(string: title, attributes: attrs)
        text.draw(in: NSRect(x: 2, y: (bounds.height - text.size().height) / 2, width: bounds.width - 4, height: text.size().height))
        if window?.firstResponder === self {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            let focus = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 9, yRadius: 9)
            focus.lineWidth = 2
            focus.stroke()
        }
    }
}
