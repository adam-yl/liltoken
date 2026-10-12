import Foundation
import Darwin

@main
struct OptionShortcutTests {
    static var assertions = 0
    static var failures: [String] = []

    static func expect(_ result: Bool, _ message: String) {
        assertions += 1
        if !result { failures.append(message) }
    }

    static func change(
        _ detector: inout DoubleOptionDetector,
        _ keys: Set<DoubleOptionDetector.OptionKey>,
        _ time: TimeInterval,
        other: Bool = false
    ) -> Bool {
        detector.modifiersChanged(optionsDown: keys, otherModifiersDown: other, time: time)
    }

    static func tap(
        _ detector: inout DoubleOptionDetector,
        _ down: TimeInterval,
        _ up: TimeInterval,
        key: DoubleOptionDetector.OptionKey = .left
    ) -> Bool {
        expect(!change(&detector, [key], down), "A press must never trigger")
        return change(&detector, [], up)
    }

    static func main() {
        for key in [DoubleOptionDetector.OptionKey.left, .right] {
            var detector = DoubleOptionDetector()
            expect(!tap(&detector, 0, 0.08, key: key), "First tap waits for its pair")
            expect(tap(&detector, 0.17, 0.25, key: key), "Two clean taps trigger on release")
            expect(!tap(&detector, 0.34, 0.42, key: key), "Third tap does not overlap the prior pair")
            expect(tap(&detector, 0.51, 0.59, key: key), "Fourth tap completes a new pair")
        }

        do {
            var detector = DoubleOptionDetector()
            expect(!tap(&detector, 0, 0.08), "Initial left tap")
            expect(!tap(&detector, 0.17, 0.25, key: .right), "Changing Option side starts a new pair")
            expect(tap(&detector, 0.34, 0.42, key: .right), "Two right taps following a left tap work")
        }

        do {
            var detector = DoubleOptionDetector()
            expect(!tap(&detector, 0, 0.08), "Initial tap before timeout")
            expect(!tap(&detector, 0.7, 0.78), "Widely spaced taps do not trigger")
            expect(tap(&detector, 0.87, 0.95), "New timely pair works after timeout")
        }

        for (down, up, message) in [
            (0.0, 0.010, "Very short press rejected"),
            (0.0, 0.400, "Long hold rejected")
        ] {
            var detector = DoubleOptionDetector()
            expect(!tap(&detector, down, up), message)
            expect(!tap(&detector, up + 0.1, up + 0.18), "Invalid hold cannot begin a pair")
        }

        do {
            var detector = DoubleOptionDetector()
            expect(!tap(&detector, 0, 0.08), "First tap before bounce")
            expect(!tap(&detector, 0.09, 0.17), "An accidental short gap is rejected")
            expect(!tap(&detector, 0.26, 0.34), "Bounce clears the pending pair")
            expect(tap(&detector, 0.43, 0.51), "Valid pair resumes after bounce")
        }

        do {
            var detector = DoubleOptionDetector()
            expect(!tap(&detector, 0, 0.08), "First tap before long second hold")
            expect(!tap(&detector, 0.17, 0.6), "Long second hold does not trigger")
            expect(!tap(&detector, 0.69, 0.77), "Long second hold clears pair")
        }

        do {
            var detector = DoubleOptionDetector()
            expect(!tap(&detector, 0, 0.08), "First tap before late second release")
            expect(!tap(&detector, 0.44, 0.6), "Pair must complete within the release interval")
            expect(tap(&detector, 0.69, 0.77), "Late but valid tap starts the next pair")
        }

        do {
            var detector = DoubleOptionDetector()
            expect(!change(&detector, [.left], 0), "First Option held")
            expect(!change(&detector, [.left, .right], 0.04), "Two held Options rejected")
            expect(!change(&detector, [.right], 0.08), "Releasing only one Option cannot unblock")
            expect(!change(&detector, [], 0.12), "Releasing both merely returns to neutral")
            expect(!tap(&detector, 0.21, 0.29), "First clean tap after both Options does not trigger")
            expect(tap(&detector, 0.38, 0.46), "Clean pair works after both Options")
        }

        do {
            var detector = DoubleOptionDetector()
            expect(!change(&detector, [.left], 0), "Option down before duplicate")
            expect(!change(&detector, [.left], 0.04), "Repeated modifier-down event rejected")
            expect(!change(&detector, [], 0.08), "Release after repeated down rejected")
            expect(!tap(&detector, 0.17, 0.25), "Repeated modifier event cleared pending pair")
        }

        do {
            var detector = DoubleOptionDetector()
            expect(!change(&detector, [.left], 0), "Option held before side jump")
            expect(!change(&detector, [.right], 0.04), "Side change without release rejected")
            expect(!change(&detector, [], 0.08), "Release after side jump rejected")
            expect(!tap(&detector, 0.17, 0.25), "Side jump cannot count as first tap")
        }

        for interruptWhileHeld in [false, true] {
            var detector = DoubleOptionDetector()
            expect(!tap(&detector, 0, 0.08), "First tap before interruption")
            if interruptWhileHeld {
                expect(!change(&detector, [.left], 0.17), "Second press before interruption")
                detector.interrupt(time: 0.20)
                expect(!change(&detector, [], 0.25), "Interrupted press does not trigger")
            } else {
                detector.interrupt(time: 0.12)
                expect(!tap(&detector, 0.17, 0.25), "Intervening mouse or modifier cancels pair")
            }
        }

        do {
            var detector = DoubleOptionDetector()
            expect(!tap(&detector, 0, 0.08), "Initial tap before typing chord")
            expect(!change(&detector, [.left], 0.17), "Option held for typing chord")
            detector.otherKeyChanged(isDown: true, isRepeat: false, time: 0.19)
            detector.otherKeyChanged(isDown: true, isRepeat: true, time: 0.21)
            detector.otherKeyChanged(isDown: false, isRepeat: false, time: 0.23)
            expect(!change(&detector, [], 0.25), "Typing and repeat cancel Option chord")
            expect(!tap(&detector, 0.34, 0.42), "Chord cannot supply first tap")
            expect(tap(&detector, 0.51, 0.59), "Repeat events do not leave a phantom held key")
        }

        do {
            var detector = DoubleOptionDetector()
            detector.otherKeyChanged(isDown: true, isRepeat: false, time: 0)
            expect(!tap(&detector, 0.1, 0.18), "Typing key held before Option blocks first tap")
            expect(!tap(&detector, 0.27, 0.35), "Typing key held across two Option taps blocks pair")
            detector.otherKeyChanged(isDown: false, isRepeat: false, time: 0.4)
            expect(!tap(&detector, 0.5, 0.58), "Released typing key allows first clean tap")
            expect(tap(&detector, 0.67, 0.75), "Released typing key allows clean pair")
        }

        do {
            var detector = DoubleOptionDetector()
            detector.otherKeyChanged(isDown: true, isRepeat: true, time: 0)
            expect(!tap(&detector, 0.1, 0.18), "Initial repeat means a typing key was already held")
            expect(!tap(&detector, 0.27, 0.35), "Initial repeat blocks an Option pair until key release")
            detector.otherKeyChanged(isDown: false, isRepeat: false, time: 0.4)
            expect(!tap(&detector, 0.5, 0.58), "Key release clears initial-repeat state")
            expect(tap(&detector, 0.67, 0.75), "Initial-repeat state does not prevent later clean pair")
        }

        do {
            var detector = DoubleOptionDetector()
            detector.otherKeyChanged(isDown: true, isRepeat: false, time: 0)
            detector.otherKeyChanged(isDown: true, isRepeat: false, time: 0.01)
            detector.otherKeyChanged(isDown: false, isRepeat: false, time: 0.02)
            expect(!tap(&detector, 0.1, 0.18), "One of two typing keys still held blocks tap")
            expect(!tap(&detector, 0.27, 0.35), "One held typing key still blocks pair")
            detector.otherKeyChanged(isDown: false, isRepeat: false, time: 0.4)
            detector.otherKeyChanged(isDown: false, isRepeat: false, time: 0.41)
            expect(!tap(&detector, 0.5, 0.58), "Extra key release cannot underflow count")
            expect(tap(&detector, 0.67, 0.75), "All typing keys released permits pair")
        }

        do {
            var detector = DoubleOptionDetector()
            detector.otherKeyChanged(isDown: true, isRepeat: false, time: 0)
            // The key release is intentionally absent: event delivery can stop
            // while a menu, password field, or another application is active.
            expect(!tap(&detector, 0.1, 0.18), "Missing typing release initially blocks a tap")
            expect(!tap(&detector, 0.27, 0.35), "Ghost held-key state initially blocks a pair")
            detector.reconcileOtherKeysHeld(false)
            expect(!tap(&detector, 0.5, 0.58), "Current released state starts a fresh tap after missing release")
            detector.reconcileOtherKeysHeld(false)
            expect(tap(&detector, 0.67, 0.75), "Current released state recovers a missing typing key-up")
        }

        do {
            var detector = DoubleOptionDetector()
            // A current held-key aggregate must block even when its original
            // key-down happened before a monitor was installed and was missed.
            detector.reconcileOtherKeysHeld(true)
            expect(!tap(&detector, 0.1, 0.18), "Current typing key held blocks an unseen key-down")
            detector.reconcileOtherKeysHeld(true)
            expect(!tap(&detector, 0.27, 0.35), "Reconciliation cannot unblock a genuinely held typing key")
            detector.reconcileOtherKeysHeld(false)
            expect(!tap(&detector, 0.5, 0.58), "Current typing release allows a first clean tap")
            expect(tap(&detector, 0.67, 0.75), "Current typing release allows a clean pair")
        }

        do {
            var detector = DoubleOptionDetector()
            expect(!tap(&detector, 0, 0.08), "First clean tap before a newly held typing key")
            expect(!change(&detector, [.left], 0.17), "Second Option press before missing typing key-down")
            detector.reconcileOtherKeysHeld(true)
            expect(!change(&detector, [], 0.25), "Current typing chord cancels a pair even when key-down was missed")
            detector.reconcileOtherKeysHeld(false)
            expect(!tap(&detector, 0.34, 0.42), "Releasing a chord cannot resurrect the earlier first tap")
            expect(tap(&detector, 0.51, 0.59), "Fresh pair works after current typing chord ends")
        }

        do {
            var detector = DoubleOptionDetector()
            detector.otherKeyChanged(isDown: true, isRepeat: false, time: 0)
            detector.otherKeyChanged(isDown: true, isRepeat: false, time: 0.01)
            // One missed release must not survive an ordinary typing down/up
            // pair and permanently disable Option recognition.
            detector.otherKeyChanged(isDown: false, isRepeat: false, time: 0.02)
            detector.otherKeyChanged(isDown: true, isRepeat: false, time: 0.1)
            detector.otherKeyChanged(isDown: false, isRepeat: false, time: 0.18)
            detector.reconcileOtherKeysHeld(false)
            expect(!tap(&detector, 0.27, 0.35), "Reconciliation discards a persistent phantom count")
            expect(tap(&detector, 0.44, 0.52), "Ordinary typing after a missing release does not disable future pairs")
        }

        for heldOptions: Set<DoubleOptionDetector.OptionKey> in [[.left], [.right], [.left, .right]] {
            var detector = DoubleOptionDetector()
            expect(!tap(&detector, 0, 0.08), "First tap before reinstalling a monitor")
            detector.reset(optionsAlreadyDown: heldOptions)
            detector.reconcileOtherKeysHeld(false)
            expect(!change(&detector, [], 0.17), "Option held across monitor recovery cannot supply a tap")
            expect(!tap(&detector, 0.26, 0.34), "Recovery discards the earlier partial pair")
            expect(tap(&detector, 0.43, 0.51), "Fresh pair works after recovered held Option is released")
        }

        for releaseHasModifier in [false, true] {
            var detector = DoubleOptionDetector()
            expect(!tap(&detector, 0, 0.08), "First tap before modified press")
            expect(!change(&detector, [.left], 0.17, other: !releaseHasModifier), "Modified press rejected")
            expect(!change(&detector, [], 0.25, other: releaseHasModifier), "Modified release rejected")
            expect(!tap(&detector, 0.34, 0.42), "Other modifier clears pair")
        }

        do {
            var detector = DoubleOptionDetector()
            expect(!tap(&detector, 1, 1.08), "First tap before reset")
            detector.reset()
            expect(!tap(&detector, 1.17, 1.25), "Reset discards first tap")
            expect(tap(&detector, 1.34, 1.42), "Fresh pair works after reset")
        }

        for invalidTime in [-1.0, Double.nan, Double.infinity, 0.01] {
            var detector = DoubleOptionDetector()
            expect(!tap(&detector, 1, 1.08), "First tap before invalid time")
            expect(!change(&detector, [.left], invalidTime), "Invalid/backwards time rejected")
            expect(!change(&detector, [], 2), "Invalid timestamp never leaves a pending press")
            expect(!tap(&detector, 2.1, 2.18), "Timestamp fault clears pair")
            expect(tap(&detector, 2.27, 2.35), "Fresh pair works after timestamp fault")
        }

        do {
            var detector = DoubleOptionDetector()
            expect(!change(&detector, [], 0), "Stray initial release rejected")
            expect(!tap(&detector, 0.1, 0.1), "Zero-duration tap rejected")
            expect(!tap(&detector, 0.2, 0.28), "Zero-duration event cannot start pair")
        }

        let aggregate: UInt = 1 << 19
        expect(DoubleOptionDetector.optionKeys(modifierFlagsRawValue: 0) == [], "Decode released state")
        expect(DoubleOptionDetector.optionKeys(modifierFlagsRawValue: aggregate | 0x20) == [.left], "Decode left Option")
        expect(DoubleOptionDetector.optionKeys(modifierFlagsRawValue: aggregate | 0x40) == [.right], "Decode right Option")
        expect(DoubleOptionDetector.optionKeys(modifierFlagsRawValue: aggregate | 0x60) == [.left, .right], "Decode both Options")
        expect(DoubleOptionDetector.optionKeys(modifierFlagsRawValue: aggregate) == nil, "Reject absent device bits")
        expect(DoubleOptionDetector.optionKeys(modifierFlagsRawValue: 0x20) == nil, "Reject absent aggregate flag")
        expect(DoubleOptionDetector.optionKeys(modifierFlagsRawValue: (1 << 17) | aggregate | 0x20) == [.left], "Other modifier bits do not alter Option side")

        if failures.isEmpty {
            print("Option shortcut: \(assertions) assertions passed (pure reducer; no input monitor started).")
            exit(0)
        }
        for failure in failures { print("FAIL: \(failure)") }
        print("Option shortcut: \(failures.count) of \(assertions) assertions failed.")
        exit(1)
    }
}
