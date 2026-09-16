import QuartzCore

/// Hold a mouse button and drag to drive Spaces/Mission Control like the trackpad gesture:
///   • horizontal drag → switch Spaces (one jump per `threshold` px, paced by a cooldown)
///   • vertical drag   → up = Mission Control, down = App Exposé; while the overlay is showing
///     (detectable on macOS 26+), only the natural reverse direction closes it — down closes
///     Mission Control, up closes App Exposé — like the real trackpad gesture
/// The active axis is locked at the start of each drag so a swipe never does both.
///
/// Click-vs-drag: the same button can ALSO carry a normal remap. A quick click (no real drag) is
/// reported back to the engine so it fires the button's mapped action; a click-and-drag does the
/// gesture instead. So one button can be e.g. Mission Control on click, switch Spaces on drag.
///
/// Horizontal drags drive the REAL WindowServer Space-slide via synthesized dock-swipe events
/// (`DockSwipeSynthesizer`), so the transition follows the pointer like a three-finger trackpad
/// swipe. Discrete Symbolic-HotKey jumps (`SystemActions`) remain the fallback — when the user
/// turns follow-finger off, or on macOS 27+ where field-based dock-swipe synthesis no longer works
/// (WindowServer reads an attached IOHIDEvent instead; not ported yet). Vertical drags stay
/// discrete (Mission Control / App Exposé are toggles, not slides). In discrete mode a fast flick
/// on release fires one extra jump for momentum feel; follow-finger gets that natively via the
/// swipe's exit speed.
///
/// State here is touched only on the event-tap thread; the public knobs are set from the same
/// thread at the top of each callback, so no locking is needed.
final class SpaceDragGesture {

    var button = 0          // 0 = disabled, else the 1-based button that triggers the gesture
    var threshold = 200.0   // pixels of horizontal drag per Space switch (discrete mode)
    var reverse = false     // flip which horizontal direction maps to which Space
    var followFinger = true // drive the real Space-slide transition when the OS supports it
    var lockPointer = false // pin the pointer at the drag origin while dragging (MMF-style)

    // Pointer-freeze hooks. Injected by the engine (real `PointerFreeze`) so tests can watch the
    // lifecycle without touching the cursor. Called on the tap thread like everything else here.
    var freezePointer: (() -> Void)?
    var unfreezePointer: (() -> Void)?

    private let dockSwipe = DockSwipeSynthesizer()
    private var followingFinger = false // this drag is driving a live dock-swipe transition
    private var swipeScale = 0.0        // originOffset per pixel, computed once per drag

    private let deadzone = 6.0           // px of movement before a press counts as a drag (not a click)
    private let hCooldown = 0.30         // s between Space switches — roughly the slide-animation duration
    private let vThreshold = 150.0       // px of vertical drag to fire Mission Control / App Exposé
    private let vCooldown = 0.40         // s between vertical triggers, so a held drag doesn't re-toggle

    // Flick-on-release: a fast release still fires one jump even below the distance threshold.
    private let flickMinDistance = 50.0  // px accumulated since the last switch
    private let flickMinVelocity = 600.0 // px/s at release
    private let flickMaxIdle = 0.08      // s — if the pointer rested longer than this, it's not a flick
    // Velocity-EMA time constant: the release speed is effectively the average over the last ~22 ms
    // of drag, REGARDLESS of the mouse's report rate. A fixed per-event weight (the old 0.7/0.3)
    // made that window report-rate dependent — ~22 ms on the 125 Hz mouse the flick thresholds were
    // tuned against, but only ~3 ms at 1000 Hz, where a single twitchy report could fake a flick.
    // 0.0224 = 8 ms / ln(1/0.7), i.e. exactly the old tuning at a 125 Hz report interval.
    private let velocitySmoothingTau = 0.0224

    private enum Axis { case undecided, horizontal, vertical }

    private var down = false
    private var dragged = false
    private var axis = Axis.undecided
    private var accX = 0.0
    private var accY = 0.0
    private var lastHSwitch = 0.0
    private var lastVTrigger = 0.0
    private var smoothedVel = 0.0        // EMA of drag speed along the active axis (px/s)
    private var lastDragTime = 0.0
    // The action that opened the currently-showing Exposé overlay; nil = none/unknown. Decides
    // which drag direction closes it. Deliberately NOT reset per drag or in cancel(): a follow-up
    // drag must still be able to close an overlay the previous drag opened. Known limitation: we
    // can't see WHICH overlay is showing, so if ours closes externally (window click) and the
    // OTHER one is later opened by keyboard/trackpad, the remembered opener picks the wrong close
    // direction until the next overlay we open ourselves overwrites it.
    private var verticalOpener: RemapAction?
    // Paces the overlay probe (a WindowServer round-trip) when triggerVertical keeps declining —
    // e.g. a sustained "wrong-direction" drag while the overlay is open re-qualifies every
    // `vThreshold` px, which unpaced means ~20 probes/s on the event-tap thread. The successful
    // path is already paced by `vCooldown`.
    private var lastVProbe = 0.0
    private let vProbeCooldown = 0.15

    var isActive: Bool { down }

    /// Abandon any in-flight press/drag WITHOUT firing actions. Needed after sleep/wake or a device
    /// disconnect: the button-up may have happened while we couldn't see it, and a stale `down`
    /// would swallow every later drag and fire spurious Space switches. Tap-thread only, like the
    /// rest of the state.
    func cancel() {
        if followingFinger {
            // Abort the live transition too, or WindowServer is left holding a half-slid Space.
            dockSwipe.post(delta: 0, type: .horizontal, phase: .cancelled)
        }
        unfreezePointer?()
        down = false
        dragged = false
        followingFinger = false
        axis = .undecided
        accX = 0; accY = 0
        smoothedVel = 0
    }

    /// Begin tracking a press of the gesture button. Returns true if this button is ours (caller
    /// should then swallow the button-down).
    func handleButtonDown(_ buttonNumber: Int) -> Bool {
        guard button != 0, buttonNumber == button else { return false }
        down = true
        dragged = false
        followingFinger = false // stale carry-over (a lost button-up) must not leak into this drag
        axis = .undecided
        accX = 0; accY = 0
        smoothedVel = 0
        // The horizontal cooldown paces switches WITHIN a drag; a new drag is a new intent, so
        // rapid successive flicks hop one Space each instead of the second being swallowed.
        // (`lastVTrigger` deliberately persists — it guards mid-animation re-toggles.)
        lastHSwitch = 0
        return true
    }

    /// End tracking. `consumed` = this was our button (swallow the up). `wasClick` = it was a plain
    /// click with no drag, so the engine should fire the button's normal remap action.
    func handleButtonUp(_ buttonNumber: Int) -> (consumed: Bool, wasClick: Bool) {
        guard down, buttonNumber == button else { return (false, false) }
        if followingFinger {
            // Release the live transition; the synthesizer completes or snaps back (and carries
            // the exit momentum) based on the final movement direction.
            dockSwipe.post(delta: 0, type: .horizontal, phase: .ended)
        } else if dragged {
            flickOnRelease()
        }
        unfreezePointer?()
        let wasClick = !dragged
        down = false
        followingFinger = false
        return (true, wasClick)
    }

    /// Pixel movement → signed swipe progress. The negation matches the trackpad convention (drag
    /// left → next Space on the right); `reverse` flips it, same as in discrete mode.
    private func swipeDelta(_ deltaX: Double) -> Double {
        (reverse ? deltaX : -deltaX) * swipeScale
    }

    /// Returns true if a drag was consumed (the gesture button is held).
    func handleDrag(deltaX: Double, deltaY: Double) -> Bool {
        guard down else { return false }
        let now = CACurrentMediaTime()

        // Wait for real movement before treating this as a drag (so a click with tiny jitter still
        // counts as a click), then lock onto the axis that moved most.
        if !dragged {
            accX += deltaX; accY += deltaY
            if max(abs(accX), abs(accY)) >= deadzone {
                dragged = true
                // Anchor only once the drag is real — a plain click must never pin the pointer.
                if lockPointer { freezePointer?() }
                axis = abs(accX) >= abs(accY) ? .horizontal : .vertical
                if axis == .horizontal, followFinger, DockSwipeSynthesizer.isSupported {
                    followingFinger = true
                    swipeScale = DockSwipeSynthesizer.horizontalScale()
                    // Open the swipe with the deadzone's accumulated movement so the transition
                    // starts exactly where the pointer already is — no dead first millimeters.
                    dockSwipe.post(delta: swipeDelta(accX), type: .horizontal, phase: .began)
                }
                accX = 0; accY = 0
                lastDragTime = now
            }
            return true
        }

        // Track drag velocity (EMA) along the active axis for flick detection on release,
        // dt-weighted so the smoothing window is wall-time (see `velocitySmoothingTau`).
        let dt = now - lastDragTime
        lastDragTime = now
        let axisDelta = axis == .horizontal ? deltaX : deltaY
        if dt > 0, dt < 0.5 {
            let alpha = 1 - exp(-dt / velocitySmoothingTau)
            smoothedVel += alpha * (axisDelta / dt - smoothedVel)
        }

        if axis == .horizontal {
            if followingFinger {
                // Follow-finger: every pixel drives the live transition; thresholds/cooldowns are
                // discrete-mode concepts. The OS handles per-Space snapping and momentum itself.
                dockSwipe.post(delta: swipeDelta(deltaX), type: .horizontal, phase: .changed)
            } else if now - lastHSwitch < hCooldown {
                accX = 0 // discard motion during the cooldown so one hard swipe = exactly one Space
            } else {
                accX += deltaX
                if abs(accX) >= threshold {
                    switchSpace(left: (accX < 0) != reverse)
                    accX = 0
                    lastHSwitch = now
                }
            }
        } else {
            accY += deltaY
            if now - lastVTrigger >= vCooldown, now - lastVProbe >= vProbeCooldown,
               abs(accY) >= vThreshold {
                lastVProbe = now
                if triggerVertical(up: accY < 0) { lastVTrigger = now }
                accY = 0
            }
        }
        return true
    }

    private func flickOnRelease() {
        let now = CACurrentMediaTime()
        // If the pointer rested before release, `smoothedVel` still holds the last movement's speed
        // (no events arrive while resting), so the idle check stops a drag-pause-release false flick.
        guard now - lastDragTime <= flickMaxIdle else { return }
        let acc = axis == .horizontal ? accX : accY
        guard abs(acc) >= flickMinDistance,
              abs(smoothedVel) >= flickMinVelocity,
              (smoothedVel > 0) == (acc > 0) else { return } // still moving in the accumulated direction

        if axis == .horizontal {
            if now - lastHSwitch >= hCooldown { // a threshold-switch just fired — don't double up
                switchSpace(left: (acc < 0) != reverse)
                lastHSwitch = now
            }
        } else if now - lastVTrigger >= vCooldown {
            if triggerVertical(up: acc < 0) { lastVTrigger = now }
        }
    }

    private func switchSpace(left: Bool) {
        (left ? SystemActions.spaceLeft : SystemActions.spaceRight)()
    }

    /// Fire the vertical action for the drag direction. Returns false when the drag does nothing
    /// (dragging further "open" while the overlay is already showing), so callers don't burn the
    /// cooldown on a no-op. Posts via RemapAction so the Dock-SPI-unavailable fallback
    /// (synthesized Ctrl+↑/↓) applies here too.
    private func triggerVertical(up: Bool) -> Bool {
        // Overlay state undetectable (pre-macOS 26): keep the legacy unconditional toggle.
        guard let overlayOpen = SystemActions.exposeOverlayIsOpen() else {
            (up ? RemapAction.missionControl : RemapAction.appExpose).post()
            return true
        }
        if !overlayOpen {
            let action: RemapAction = up ? .missionControl : .appExpose
            action.post()
            verticalOpener = action
            return true
        }
        // Overlay is open — the opener toggles it closed, but only in the natural direction
        // (down closes Mission Control, up closes App Exposé), like the real trackpad gesture.
        // Opener unknown (overlay opened by keyboard/trackpad): assume the drag direction closes.
        let opener = verticalOpener ?? (up ? RemapAction.appExpose : RemapAction.missionControl)
        let closes = opener == .missionControl ? !up : up
        guard closes else { return false }
        opener.post()
        verticalOpener = nil
        return true
    }
}
