import CoreGraphics
import Foundation

/// Hold the pointer still for the duration of a drag gesture (Mac Mouse Fix's "freeze pointer"
/// mode — the puppet-cursor variant needs private CGS APIs and is not ported).
///
/// Mechanism: a second event tap watches mouse-move/drag events and warps the pointer back to
/// the freeze origin on each one. The gesture keeps seeing full physical deltas (they come from
/// the HID report, not the pointer position), so only the on-screen cursor stops. While frozen the
/// event-source suppression interval is lowered — after a warp macOS otherwise ignores hardware
/// mouse input for ~0.25 s, so the cursor would lag the drag — and restored on unfreeze.
///
/// Threading: `install`/`uninstall` run on the engine's tap thread (its run loop owns the tap);
/// `freeze`/`unfreeze` are called from the drag gesture, which is tap-thread-only; the tap's own
/// callback fires on that thread too. So no locking, same discipline as `SpaceDragGesture`.
final class PointerFreeze {

    static let shared = PointerFreeze()
    private init() {}

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var origin = CGPoint.zero
    private(set) var isFrozen = false

    /// macOS default; restored on unfreeze.
    private static let defaultSuppression = 0.25
    /// Lowest interval at which repeated warps still hold the pointer (0 makes
    /// `CGWarpMouseCursorPosition` stop working entirely) — MMF's tuning.
    private static let frozenSuppression = 0.07

    /// Create the tap on `runLoop` (the tap thread's). Starts disabled — it only works while frozen.
    func install(on runLoop: CFRunLoop) {
        uninstall(from: runLoop)
        let mask: CGEventMask =
            (1 << CGEventType.mouseMoved.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.rightMouseDragged.rawValue) |
            (1 << CGEventType.otherMouseDragged.rawValue)
        guard let created = CGEvent.tapCreate(
            tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, _ in
                PointerFreeze.shared.handle(type: type)
                return Unmanaged.passUnretained(event)
            },
            userInfo: nil) else {
            NSLog("Mousse: pointer-freeze event tap could not be created")
            return
        }
        tap = created
        if let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0) {
            source = src
            CFRunLoopAddSource(runLoop, src, .commonModes)
        }
        CGEvent.tapEnable(tap: created, enable: false)
    }

    /// Tear the tap down (releasing the pointer first). Paired with the engine's tap rebuild so a
    /// wake never leaves the cursor pinned or the suppression interval lowered.
    func uninstall(from runLoop: CFRunLoop) {
        unfreeze()
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source { CFRunLoopRemoveSource(runLoop, source, .commonModes) }
        CFMachPortInvalidate(tap)
        self.tap = nil
        source = nil
    }

    /// Pin the pointer at `position` until `unfreeze`. Idempotent; no-op if the tap is missing.
    func freeze(at position: CGPoint) {
        guard !isFrozen, let tap else { return }
        origin = position
        setSuppression(PointerFreeze.frozenSuppression)
        isFrozen = true
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    /// Release the pointer, parking it exactly on the origin. Idempotent.
    func unfreeze() {
        guard isFrozen else { return }
        isFrozen = false
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        CGWarpMouseCursorPosition(origin)
        setSuppression(PointerFreeze.defaultSuppression)
    }

    private func handle(type: CGEventType) {
        guard isFrozen else { return }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        CGWarpMouseCursorPosition(origin)
    }

    private func setSuppression(_ interval: Double) {
        CGEventSource(stateID: .combinedSessionState)?.localEventsSuppressionInterval = interval
    }
}
