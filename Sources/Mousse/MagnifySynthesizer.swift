import AppKit
import CoreGraphics
import QuartzCore
import os

/// Synthesizes trackpad pinch-zoom (magnification) gestures from Cmd+scroll-wheel ticks — a real
/// pinch, so it zooms anything a trackpad pinch zooms (browsers, Preview, Maps, Figma…), unlike
/// Cmd+"+" key presses.
///
/// Smoothing: a wheel notch is one big magnification step (~7.5 %), which canvas apps (Figma,
/// Sketch, Maps) render as a visible JUMP per click. Real pinches arrive as a dense stream of tiny
/// deltas, so instead of posting a notch at once we queue it and drain it over a short
/// exponential ease (`tau`) from a 120 Hz timer — the total zoom per notch is unchanged, it just
/// glides. A reversed notch drops the queued remainder so direction flips stay immediate.
///
/// Stream shape: the first drained frame opens the gesture (began carries its delta; Chromium
/// gets an empty began + front-loaded changed, see `feed`), later frames are `changed`, and the
/// gesture closes with an empty `ended` once the queue is empty and the wheel has been quiet for
/// `endTimeout` (we can't see the Cmd key-up — the tap only listens to mouse events).
///
/// Threading: `feed` runs on the event-tap thread; the drain timer fires on `animQueue`. State is
/// guarded by `lock`, and every phase event is POSTED while still holding it, so the emitted
/// stream order always matches the state transitions (a `began` can never be overtaken by the
/// `ended` of the previous gesture). CGEventPost is thread-safe and takes microseconds, so holding
/// the lock across it is harmless.
final class MagnifySynthesizer {

    /// Field-based gesture synthesis works through macOS 26; macOS 27 stops reading these fields
    /// (same WindowServer change that breaks DockSwipeSynthesizer). There, fall back to quantized,
    /// rate-limited Cmd+= / Cmd+− keystrokes — zooms browsers/editors, though not pinch-only
    /// surfaces like Maps.
    static let pinchSupported = ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 27

    // Keystroke-fallback state: touched only on the event-tap thread (the fallback branch of
    // `feed` is the sole user), so it needs no lock — unlike the pinch state below.
    private var zoomQuantizer = ZoomQuantizer()

    // Unfair lock (not NSLock): `feed` runs per zoom event on the tap thread — hundreds per
    // second on a free-spin flick. Not recursive; posting under it stays a few microseconds.
    private let lock = OSAllocatedUnfairLock()
    private var active = false          // a began has been posted and no ended yet
    private var pending = 0.0           // magnification queued but not yet posted
    private var boostOnOpen = false     // open the next gesture Chromium-style (see `feed`)
    private let endTimeout = 0.25       // s of wheel silence (with nothing queued) before ending
    private var lastFeed = 0.0          // CACurrentMediaTime of the most recent tick
    private var lastFrame = 0.0         // previous drain frame, for a frame-rate-independent ease
    private var timer: DispatchSourceTimer?  // non-nil while a gesture is queued or open

    private let tau = 0.045             // s — ease time constant; ~95 % of a notch lands in 0.13 s
    private let flushEpsilon = 0.0005   // queued magnification below this is posted in one go
    private let maxPending = 1.5        // bound the queue so a hard flick can't zoom on for long
    private let frameInterval = DispatchTimeInterval.nanoseconds(8_333_333) // 120 Hz

    /// Drain timer queue. Separate from the tap thread so smoothing never delays input handling.
    private let animQueue = DispatchQueue(label: "com.mousse.magnify", qos: .userInteractive)

    private let phaseBegan: Int64 = 1   // IOHIDEventPhaseBits
    private let phaseChanged: Int64 = 2
    private let phaseEnded: Int64 = 4

    /// Feed one wheel tick's worth of zoom. `magnification` is the signed pinch delta
    /// (positive = zoom in); `chromiumBoost` should be true when the app under the cursor is a
    /// Chromium browser — they swallow small pinch deltas, so the gesture opens with a big first
    /// step to feel responsive (a long-standing upstream workaround).
    func feed(magnification: Double, chromiumBoost: Bool) {
        guard magnification != 0, magnification.isFinite else { return }

        guard MagnifySynthesizer.pinchSupported else {
            // macOS 27+: quantize the tick stream into whole, rate-limited zoom steps (Cmd+= in,
            // Cmd+− out) — one keystroke per raw event would zoom-storm on free-spin/continuous
            // mice, whose flicks are dozens to hundreds of events.
            let fired = zoomQuantizer.feed(magnification, at: CACurrentMediaTime())
            if fired != 0 { MagnifySynthesizer.postZoomKeystroke(zoomIn: fired > 0) }
            return
        }

        let now = CACurrentMediaTime()
        lock.lock()
        // Direction flip: drop what is still queued the old way so the reversal is immediate.
        if pending != 0, (pending > 0) != (magnification > 0) { pending = 0 }
        pending = min(max(pending + magnification, -maxPending), maxPending)
        lastFeed = now
        if !active { boostOnOpen = chromiumBoost }
        var started: DispatchSourceTimer?
        if timer == nil {
            let t = DispatchSource.makeTimerSource(queue: animQueue)
            t.schedule(deadline: .now(), repeating: frameInterval, leeway: .milliseconds(1))
            t.setEventHandler { [weak self] in self?.frame() }
            timer = t
            lastFrame = now
            started = t
        }
        lock.unlock()
        started?.resume() // outside the lock: the first frame may fire immediately
    }

    /// One drain frame (on `animQueue`): post the eased share of the queue, or end the gesture
    /// once nothing is queued and the wheel has been quiet for `endTimeout`.
    private func frame() {
        lock.lock()
        defer { lock.unlock() }
        let now = CACurrentMediaTime()
        let dt = min(max(now - lastFrame, 0), 0.05)
        lastFrame = now

        if pending != 0 {
            var d = pending * (1 - exp(-dt / tau))
            if abs(pending - d) < flushEpsilon { d = pending }
            guard d != 0 else { return }
            pending -= d
            if !active {
                active = true
                if boostOnOpen {
                    // Chromium needs a pile of deltas before it starts zooming; front-load them.
                    post(phase: phaseBegan, magnification: 0)
                    post(phase: phaseChanged,
                         magnification: d + (d > 0 ? 380.0 / 800.0 : -250.0 / 800.0))
                } else {
                    post(phase: phaseBegan, magnification: d)
                }
            } else {
                post(phase: phaseChanged, magnification: d)
            }
            return
        }

        // Queue empty: keep the gesture open through short pauses between notches (one pinch,
        // not began/ended churn), then close it and stop the timer.
        guard now - lastFeed >= endTimeout else { return }
        if active { post(phase: phaseEnded, magnification: 0) } // under lock — see class comment
        active = false
        timer?.cancel()
        timer = nil
    }

    /// Close any open pinch immediately (wake/space-switch teardowns) and drop whatever is queued.
    func endNow() {
        lock.lock()
        pending = 0
        if active { post(phase: phaseEnded, magnification: 0) } // under lock — see class comment
        active = false
        timer?.cancel()
        timer = nil
        lock.unlock()
    }

    /// Serial queue so the fallback keystroke is synthesized OFF the event-tap thread — same
    /// rationale as `RemapAction.keyQueue` (posting from inside the tap callback can stall it).
    private static let keyQueue = DispatchQueue(label: "com.mousse.zoom-keystroke", qos: .userInteractive)

    /// Keystroke fallback for OSes that ignore synthetic gesture events: Cmd+'=' / Cmd+'-'
    /// (ANSI key codes 0x18 / 0x1B), the universal app zoom shortcut.
    private static func postZoomKeystroke(zoomIn: Bool) {
        keyQueue.async {
            let keyCode: CGKeyCode = zoomIn ? 0x18 : 0x1B
            for down in [true, false] {
                guard let e = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: down)
                else { continue }
                e.flags = .maskCommand
                e.post(tap: .cghidEventTap)
            }
        }
    }

    private func post(phase: Int64, magnification: Double) {
        guard let e = CGEvent(source: nil) else { return }
        e.setDoubleValueField(CGEventField(rawValue: 55)!, value: 29)  // NSEventTypeGesture
        e.setIntegerValueField(CGEventField(rawValue: 110)!, value: 8) // kIOHIDEventTypeZoom
        e.setIntegerValueField(CGEventField(rawValue: 132)!, value: phase)
        e.setDoubleValueField(CGEventField(rawValue: 113)!, value: magnification)
        e.post(tap: .cghidEventTap)
    }
}
