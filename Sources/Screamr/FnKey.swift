import CoreGraphics
import Foundation

/// Reports Fn (Globe) press and release system-wide through a listen-only event tap.
final class FnKey {
    var onChange: ((Bool) -> Void)?
    private var tap: CFMachPort?
    private var isDown = false

    /// Returns false when the tap can't be created (Accessibility / Input Monitoring not granted yet).
    func start() -> Bool {
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, ctx in
                let me = Unmanaged<FnKey>.fromOpaque(ctx!).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = me.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                } else {
                    me.handle(event)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: me
        ) else { return false }
        self.tap = tap
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func handle(_ event: CGEvent) {
        // Arrow and F-row keys also set the Fn flag; only the Fn key itself (keycode 63) counts.
        guard event.getIntegerValueField(.keyboardEventKeycode) == 63 else { return }
        let down = event.flags.contains(.maskSecondaryFn)
        guard down != isDown else { return }
        isDown = down
        onChange?(down)
    }
}
