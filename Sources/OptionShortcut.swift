import AppKit
import ApplicationServices
import Carbon

/// A deterministic reducer for two clean taps of the same Option key.
/// It retains modifier identity and timing, never typed characters or key codes.
struct DoubleOptionDetector {
    enum OptionKey: Hashable { case left, right }

    private struct Press {
        let key: OptionKey
        let began: TimeInterval
    }

    private struct Tap {
        let key: OptionKey
        let ended: TimeInterval
    }

    // Deliberately reject switch bounce and long holds used for typing shortcuts.
    static let minimumHold: TimeInterval = 0.025
    static let maximumHold: TimeInterval = 0.30
    static let minimumGap: TimeInterval = 0.045
    static let maximumReleaseInterval: TimeInterval = 0.45

    private var optionsDown: Set<OptionKey> = []
    private var press: Press?
    private var firstTap: Tap?
    private var blockedUntilRelease = false
    private var otherKeysHeld = 0
    private var lastTime: TimeInterval?

    mutating func reset(optionsAlreadyDown: Set<OptionKey> = []) {
        self = DoubleOptionDetector()
        optionsDown = optionsAlreadyDown
        blockedUntilRelease = !optionsAlreadyDown.isEmpty
    }

    /// Correct an anonymous held-key count from a current-state aggregate. Event
    /// monitors can miss a release; it must not disable the shortcut forever.
    /// The caller supplies no key identity, characters, or event history.
    mutating func reconcileOtherKeysHeld(_ anyDown: Bool) {
        otherKeysHeld = anyDown ? 1 : 0
        if anyDown {
            cancelPending()
            blockedUntilRelease = !optionsDown.isEmpty
        }
    }

    /// Returns true only when the second complete Option tap is released.
    mutating func modifiersChanged(
        optionsDown nextOptions: Set<OptionKey>,
        otherModifiersDown: Bool,
        time: TimeInterval
    ) -> Bool {
        guard accept(time: time) else { return false }
        let previousOptions = optionsDown
        optionsDown = nextOptions

        guard !otherModifiersDown, otherKeysHeld == 0, nextOptions.count < 2 else {
            cancelPending()
            blockedUntilRelease = !nextOptions.isEmpty
            return false
        }

        if blockedUntilRelease {
            if nextOptions.isEmpty { blockedUntilRelease = false }
            return false
        }

        if nextOptions.isEmpty {
            guard previousOptions.count == 1,
                  let completedPress = press,
                  previousOptions.contains(completedPress.key) else {
                cancelPending()
                return false
            }
            press = nil
            let duration = time - completedPress.began
            guard duration >= Self.minimumHold, duration <= Self.maximumHold else {
                firstTap = nil
                return false
            }

            if let first = firstTap,
               first.key == completedPress.key,
               completedPress.began - first.ended >= Self.minimumGap,
               time - first.ended <= Self.maximumReleaseInterval {
                firstTap = nil
                return true
            }

            firstTap = Tap(key: completedPress.key, ended: time)
            return false
        }

        // Two Option keys together, duplicate downs, and missing releases cannot
        // become valid taps. Wait for a neutral state before trying again.
        guard previousOptions.isEmpty, let key = nextOptions.first else {
            cancelPending()
            blockedUntilRelease = true
            return false
        }

        if let first = firstTap {
            if time - first.ended < Self.minimumGap {
                cancelPending()
                blockedUntilRelease = true
                return false
            }
            if key != first.key || time - first.ended > Self.maximumReleaseInterval {
                firstTap = nil
            }
        }
        press = Press(key: key, began: time)
        return false
    }

    /// Only a count is kept, so holding a typing key cannot turn into the shortcut.
    /// Neither the key's identity nor its text is accepted by this interface.
    mutating func otherKeyChanged(isDown: Bool, isRepeat: Bool, time: TimeInterval) {
        guard accept(time: time) else { return }
        if isDown {
            // A repeat can be the first event after attaching a monitor while
            // someone is already holding a key.
            otherKeysHeld = isRepeat ? max(otherKeysHeld, 1) : min(otherKeysHeld + 1, 256)
        } else if !isDown {
            otherKeysHeld = max(otherKeysHeld - 1, 0)
        }
        cancelPending()
        blockedUntilRelease = !optionsDown.isEmpty
    }

    /// Mouse input or a non-Option modifier change interrupts a possible pair.
    mutating func interrupt(time: TimeInterval) {
        guard accept(time: time) else { return }
        cancelPending()
        blockedUntilRelease = !optionsDown.isEmpty
    }

    private mutating func cancelPending() {
        press = nil
        firstTap = nil
    }

    private mutating func accept(time: TimeInterval) -> Bool {
        guard time.isFinite, time >= 0, lastTime.map({ time >= $0 }) ?? true else {
            reset()
            if time.isFinite && time >= 0 { lastTime = time }
            return false
        }
        lastTime = time
        return true
    }

    /// NSEvent preserves the device-specific bits from IOKit/IOLLEvent.h.
    /// Reject an inconsistent aggregate flag instead of guessing a key state.
    static func optionKeys(modifierFlagsRawValue flags: UInt) -> Set<OptionKey>? {
        let leftDown = flags & 0x00000020 != 0 // NX_DEVICELALTKEYMASK
        let rightDown = flags & 0x00000040 != 0 // NX_DEVICERALTKEYMASK
        let aggregateDown = flags & (1 << 19) != 0 // NSEventModifierFlagOption
        guard aggregateDown == (leftDown || rightDown) else { return nil }
        var keys: Set<OptionKey> = []
        if leftDown { keys.insert(.left) }
        if rightDown { keys.insert(.right) }
        return keys
    }
}

/// A passive monitor: all local events are returned unchanged and global events
/// cannot be intercepted. No text, input history, or shortcut events are logged.
final class OptionShortcut {
    private var detector = DoubleOptionDetector()
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var appObservers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var onTrigger: (() -> Void)?

    /// Installation state only. This callback never reports input activity.
    var onStateChanged: (() -> Void)?
    var isMonitoring: Bool { globalMonitor != nil && localMonitor != nil }

    /// A read-only check. This never prompts or changes macOS privacy settings.
    static var isAuthorized: Bool { AXIsProcessTrusted() }
    static var isSecureInputActive: Bool { IsSecureEventInputEnabled() }

    /// Call only after the user chooses to enable the shortcut. The app must have
    /// Accessibility authorization; an unapproved call installs no input monitor.
    @discardableResult
    func start(forceRestart: Bool = false, onTrigger: @escaping () -> Void) -> Bool {
        guard Thread.isMainThread else { return false }
        guard Self.isAuthorized else {
            stop()
            return false
        }
        self.onTrigger = onTrigger
        if isMonitoring && !forceRestart { return true }
        stop()
        self.onTrigger = onTrigger
        resetForCurrentModifiers()

        let mask: NSEvent.EventTypeMask = [
            .flagsChanged, .keyDown, .keyUp, .leftMouseDown,
            .rightMouseDown, .otherMouseDown, .scrollWheel
        ]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
        }
        guard globalMonitor != nil else {
            stop()
            return false
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
            return event
        }
        guard localMonitor != nil else {
            stop()
            return false
        }

        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            appObservers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in self?.resetForCurrentModifiers() })
        }
        workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.resetForCurrentModifiers() })
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification,
                     NSWorkspace.didActivateApplicationNotification] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in self?.recoverMonitoring() })
        }
        onStateChanged?()
        return true
    }

    func stop() {
        let wasMonitoring = globalMonitor != nil || localMonitor != nil
        if let monitor = globalMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = localMonitor { NSEvent.removeMonitor(monitor) }
        globalMonitor = nil
        localMonitor = nil
        for observer in appObservers { NotificationCenter.default.removeObserver(observer) }
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        appObservers.removeAll()
        workspaceObservers.removeAll()
        onTrigger = nil
        detector.reset()
        if wasMonitoring { onStateChanged?() }
    }

    deinit { stop() }

    private func resetForCurrentModifiers() {
        let flags = NSEvent.modifierFlags
        // If device bits are unavailable while Option is held, block both sides
        // conservatively until release instead of interpreting a partial tap.
        let held = DoubleOptionDetector.optionKeys(modifierFlagsRawValue: flags.rawValue)
            ?? (flags.contains(.option) ? [.left, .right] : [])
        detector.reset(optionsAlreadyDown: held)
    }

    private func recoverMonitoring() {
        guard let callback = onTrigger else { return }
        _ = start(forceRestart: true, onTrigger: callback)
    }

    /// Called only for Option modifier events while trusted and outside secure
    /// input. Reduce the current virtual-key table immediately to one Boolean;
    /// no individual key state is kept, decoded, or logged. Modifier keys are
    /// handled separately by the event flags, including latched Caps Lock.
    private static func anyTypingKeyDown() -> Bool {
        for code in CGKeyCode(0)...CGKeyCode(127) {
            if (54...63).contains(code) { continue }
            if CGEventSource.keyState(.combinedSessionState, key: code) { return true }
        }
        return false
    }

    private func handle(_ event: NSEvent) {
        // Respect macOS's secure-input boundary even for local events. Never try
        // to turn it off or probe held typing keys while it is active.
        guard !Self.isSecureInputActive else {
            resetForCurrentModifiers()
            return
        }
        switch event.type {
        case .flagsChanged:
            guard event.keyCode == 58 || event.keyCode == 61 else {
                detector.interrupt(time: event.timestamp)
                return
            }
            // Recheck trust before probing current state; ordinary typing does
            // not make additional Accessibility requests on every keystroke.
            guard Self.isAuthorized else {
                resetForCurrentModifiers()
                return
            }
            guard let options = DoubleOptionDetector.optionKeys(
                modifierFlagsRawValue: event.modifierFlags.rawValue
            ) else {
                resetForCurrentModifiers()
                return
            }
            detector.reconcileOtherKeysHeld(Self.anyTypingKeyDown())
            let conflictingModifiers: NSEvent.ModifierFlags = [.command, .control, .shift, .function]
            if detector.modifiersChanged(
                optionsDown: options,
                otherModifiersDown: !event.modifierFlags.intersection(conflictingModifiers).isEmpty,
                time: event.timestamp
            ) { onTrigger?() }
        case .keyDown, .keyUp:
            detector.otherKeyChanged(
                isDown: event.type == .keyDown,
                isRepeat: event.isARepeat,
                time: event.timestamp
            )
        default:
            detector.interrupt(time: event.timestamp)
        }
    }
}
