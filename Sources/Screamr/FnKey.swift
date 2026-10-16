import CoreGraphics
import Foundation

/// System-wide Fn (Globe), Space and Esc events through a filtering event tap, so keys
/// used as dictation gestures can be kept away from the focused app.
final class FnKey {
    enum Event { case fnDown, fnUp, space, escape, meetingToggle }

    /// Return true to swallow the key. Fn itself is never swallowed.
    var onEvent: ((Event) -> Bool)?
    private var tap: CFMachPort?
    private var isDown = false

    /// Returns false when the tap can't be created (Accessibility not granted yet).
    func start() -> Bool {
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue) | CGEventMask(1 << CGEventType.keyDown.rawValue)
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, ctx in
                let me = Unmanaged<FnKey>.fromOpaque(ctx!).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = me.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                    return Unmanaged.passUnretained(event)
                }
                return me.handle(type, event) ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: me
        ) else { return false }
        self.tap = tap
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        if type == .keyDown {
            guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return false }
            let hyper: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]
            if keycode == 46, event.flags.intersection([.maskControl, .maskAlternate, .maskCommand, .maskShift]) == hyper {
                return onEvent?(.meetingToggle) ?? false // Ctrl+Opt+Cmd+M
            }
            switch keycode {
            case 49: return onEvent?(.space) ?? false
            case 53: return onEvent?(.escape) ?? false
            default: return false
            }
        }
        // Arrow and F-row keys also set the Fn flag; only the Fn key itself (keycode 63) counts.
        guard keycode == 63 else { return false }
        let down = event.flags.contains(.maskSecondaryFn)
        guard down != isDown else { return false }
        isDown = down
        _ = onEvent?(down ? .fnDown : .fnUp)
        return false
    }
}
