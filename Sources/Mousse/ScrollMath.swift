import Foundation

/// Mac-Mouse-Fix-style smooth-scroll math (v3). Clean-room re-derivation of the published model;
/// only the *tuning constants* are taken from , the code is original. Three user-selectable
/// profiles (`ScrollSmoothness` → `ScrollProfile`) plus dedicated precise/quick modifier
/// profiles.
///
/// The model, per wheel notch:
///   1. `TickAnalyzer` measures the tick rate (rolling average of the last 3 inter-tick gaps)
///      and counts consecutive "swipes" (bursts of ≥3 rapid ticks) for fast-scroll.
///   2. `ScrollTuning.pxPerTick` maps tick rate → pixels for this notch (a capped linear
///      sensitivity curve: minSens at ≤6.25 ticks/s rising to maxSens at 66.7 ticks/s).
///   3. `SpeedupCurve` multiplies the notch distance exponentially once the user chains swipes
///      ('s "fast scroll" — flinging through long documents).
///   4. `HybridPlan` re-plans the glide: remaining distance + new notch distance are covered by
///      a short bezier whose *initial slope equals the current glide speed* (speed smoothing — no
///      velocity jump on retarget), handed off to a physical drag curve v' = −a·v^b that decays to
///      `stopSpeed`. The drag tail is what gives  its signature inertial coast.
enum ScrollTuning {

    static let maxDuration = 1.5          // s — fast-scroll animations are compressed to this

    /// Tick-rate window ( ScrollAnalyzer): gaps outside [15 ms, 160 ms] are clamped; a gap
    /// above the max starts a new tick sequence.
    static let tickIntervalMin = 0.015
    static let tickIntervalMax = 0.160

    /// The acceleration curve is linear from (1/tickIntervalMax, minSens) to
    /// (1/tickIntervalMin, maxSens), clamped below, linearly extended above ( curvature 0).
    static func pxPerTick(tickHz: Double, minSens: Double, maxSens: Double) -> Double {
        let xMin = 1.0 / tickIntervalMax
        let xMax = 1.0 / tickIntervalMin
        let slope = (maxSens - minSens) / (xMax - xMin)
        return max(minSens, minSens + slope * (tickHz - xMin))
    }
}

/// The user-facing smoothness setting — three -derived curve profiles.
enum ScrollSmoothness: String, Codable, Sendable, CaseIterable {
    case snappy   //  "Regular" as shipped — direct, minimal tail
    case balanced // 's softened-Regular alternative — smooth but responsive (default)
    case floaty   //  "High" — long trackpad-like coast

    var label: String {
        switch self {
        case .snappy:   return "Snappy (direct)"
        case .balanced: return "Balanced"
        case .floaty:   return "Floaty (trackpad)"
        }
    }
}

/// One complete curve + sensitivity tuning. The engine resolves a profile per tick from the
/// smoothness setting and any held modifier (Option → precise, Ctrl → quick).
struct ScrollProfile {
    let baseMsPerStep: Double     // s — base (gesture) portion target duration
    let speedSmoothing: Double    // bezier reach along the current-speed direction (0 = linear)
    let dragCoefficient: Double   // a in v' = −a·v^b
    let dragExponent: Double      // b
    let stopSpeed: Double         // px/s — drag tail ends here
    let minSensAnchors: (lo: Double, mid: Double, hi: Double) // px/tick at slider 0 / 0.5 / 1
    let maxSensAnchors: (lo: Double, mid: Double, hi: Double)
    let speedup: SpeedupCurve? // fast-scroll multiplier; nil → never speeds up
    // Swipe-chaining window ( varies these per curve: floatier curves chain more forgivingly).
    var swipeMaxInterval = 0.375   // s between bursts to still chain the swipe counter
    var swipeMinTickSpeed = 16.0   // ticks/s averaged over the sequence

    ///  "Regular" as shipped: linear base, steep drag — snappy and direct.
    static let snappy = ScrollProfile(
        baseMsPerStep: 0.140, speedSmoothing: 0.0, dragCoefficient: 15, dragExponent: 1.05,
        stopSpeed: 30, minSensAnchors: (30, 60, 120), maxSensAnchors: (90, 120, 180),
        speedup: .regular)

    /// The alternative Regular tuning noted in 's ScrollConfig ("still super responsive and
    /// much smoother feeling"): speed smoothing for velocity continuity, gentler drag.
    static let balanced = ScrollProfile(
        baseMsPerStep: 0.175, speedSmoothing: 0.15, dragCoefficient: 25, dragExponent: 0.9,
        stopSpeed: 30, minSensAnchors: (30, 60, 120), maxSensAnchors: (90, 120, 180),
        speedup: .regular)

    ///  "High": long, floaty trackpad-like coast; fast scroll kicks in a swipe earlier.
    static let floaty = ScrollProfile(
        baseMsPerStep: 0.220, speedSmoothing: 0.15, dragCoefficient: 40, dragExponent: 0.7,
        stopSpeed: 30, minSensAnchors: (60, 90, 150), maxSensAnchors: (120, 180, 240),
        speedup: SpeedupCurve(swipeThreshold: 2, initialSpeedup: 1.33, exponentialSpeedup: 7.5),
        swipeMaxInterval: 0.6, swipeMinTickSpeed: 12)

    /// Option-modifier precise scrolling ( PreciseScroll): a few px per tick for fine control,
    /// snappy curve, no fast scroll. Slider-independent (constant anchors).
    static let precise = ScrollProfile(
        baseMsPerStep: 0.140, speedSmoothing: 0.0, dragCoefficient: 15, dragExponent: 1.05,
        stopSpeed: 50, minSensAnchors: (2, 2, 2), maxSensAnchors: (20, 20, 20),
        speedup: nil)

    /// Ctrl-modifier quick scrolling ( QuickScroll): each notch moves about half a window,
    /// long inertial coast, aggressive speedup. Sensitivity comes from the screen span under the
    /// cursor, not the slider ( scales to 85% of the screen as the "window size").
    static func quick(screenSpan: Double) -> ScrollProfile {
        let window = max(screenSpan, 400) * 0.85
        return ScrollProfile(
            baseMsPerStep: 0.300, speedSmoothing: 0.0, dragCoefficient: 30, dragExponent: 0.7,
            stopSpeed: 1,
            minSensAnchors: (window * 0.5, window * 0.5, window * 0.5),
            maxSensAnchors: (window * 1.5, window * 1.5, window * 1.5),
            speedup: SpeedupCurve(swipeThreshold: 1, initialSpeedup: 2.0, exponentialSpeedup: 10),
            swipeMaxInterval: 0.725, swipeMinTickSpeed: 12)
    }

    static func forSmoothness(_ s: ScrollSmoothness) -> ScrollProfile {
        switch s {
        case .snappy:   return .snappy
        case .balanced: return .balanced
        case .floaty:   return .floaty
        }
    }

    /// (minSens, maxSens) px/tick for the speed slider (anchors at 0 / 0.5 / 1, linear extension
    /// past 1 — Mousse's slider runs 0.05…1.5) and the display under the cursor: maxSens gets
    /// a 10%-weighted scale by screen span relative to a 1080p baseline ('s screen scaling),
    /// so big displays fling proportionally farther.
    func sensitivity(slider: Double, screenSizeFactor: Double = 1.0) -> (minSens: Double, maxSens: Double) {
        func piecewise(_ a: (lo: Double, mid: Double, hi: Double)) -> Double {
            if slider <= 0 { return a.lo }
            if slider <= 0.5 { return a.lo + (a.mid - a.lo) * (slider / 0.5) }
            return a.mid + (a.hi - a.mid) * ((slider - 0.5) / 0.5) // continues linearly past 1.0
        }
        let screenSizeWeight = 0.1
        let maxSens = piecewise(maxSensAnchors)
        return (piecewise(minSensAnchors),
                maxSens * (1 - screenSizeWeight) + maxSens * screenSizeWeight * screenSizeFactor)
    }
}

/// 's fast-scroll multiplier: 1.0 until `threshold` consecutive swipes, then an exponential
/// ramp `a·1.1^((x−t)·c) + 1 − a` scaled so the first speedup step is `initialSpeedup`.
struct SpeedupCurve {
    let threshold: Double
    private let a: Double
    private let c: Double

    /// LowInertia ("Regular") tuning: kicks in on the 4th chained swipe, ×1.33 then ~×2 per
    /// further swipe. (HighInertia uses swipeThreshold 2 — one swipe earlier.)
    static let regular = SpeedupCurve(swipeThreshold: 3, initialSpeedup: 1.33, exponentialSpeedup: 7.5)

    init(swipeThreshold t: Int, initialSpeedup p: Double, exponentialSpeedup c: Double) {
        self.threshold = Double(t)
        self.c = c
        self.a = (p - 1.0) / (pow(1.1, c) - 1.0)
    }

    func factor(swipes: Double) -> Double {
        let x = swipes + 1 //  counts swipes from 0
        guard x >= threshold else { return 1.0 }
        return min(a * pow(1.1, (x - threshold) * c) + 1 - a, 100_000)
    }
}

/// Tick-rate + swipe analysis ( ScrollAnalyzer). Feed every wheel notch; returns the smoothed
/// tick rate that drives the acceleration curve, the consecutive-swipe count that drives fast
/// scroll, and whether this notch starts a fresh sequence (leftover glide distance is dropped).
struct TickAnalyzer {

    struct Result {
        var tickHz: Double        // smoothed, clamped to [6.25, 66.7]
        var swipes: Double        // consecutive-swipe count (free-spin wheels count fractionally)
        var isSequenceStart: Bool // true → discard the previous glide's leftover distance
    }

    private var lastTickTime = 0.0
    private var lastDirection = 0
    private var consecutiveTicks = 0      // 0-based position within the current burst
    private var swipes = 0.0
    private var ticksInSequence = 0
    private var sequenceStartTime = 0.0
    private var gapWindow: [Double] = []  // rolling average, capacity 3

    private static let swipeMinTicks = 2         // previous burst needs a tick counter ≥ this
    private static let freeSpinTicksPerSwipe = 11.0

    mutating func reset() {
        lastTickTime = 0
        lastDirection = 0
        consecutiveTicks = 0
        swipes = 0
        ticksInSequence = 0
        sequenceStartTime = 0
        gapWindow.removeAll(keepingCapacity: true)
    }

    /// `direction`: any stable key that changes on axis or sign flips (e.g. ±1 / ±2).
    /// `swipeMaxInterval`/`swipeMinTickSpeed` come from the active profile (floatier curves
    /// chain fast-scroll swipes more forgivingly, per ).
    mutating func feed(now: Double, direction: Int,
                       swipeMaxInterval: Double = 0.375, swipeMinTickSpeed: Double = 16) -> Result {
        if direction != lastDirection {
            reset()
            lastDirection = direction
        }

        let rawGap = max(now - lastTickTime, ScrollTuning.tickIntervalMin)
        ticksInSequence += 1

        if rawGap > ScrollTuning.tickIntervalMax {
            // First tick of a new burst — decide whether it chains the swipe count.
            let previousBurstLongEnough = consecutiveTicks >= TickAnalyzer.swipeMinTicks
            let closeEnough = rawGap <= swipeMaxInterval
            let sequenceElapsed = now - sequenceStartTime
            let fastEnough = sequenceElapsed > 0
                && Double(ticksInSequence) / sequenceElapsed >= swipeMinTickSpeed
            if previousBurstLongEnough, closeEnough, fastEnough, lastTickTime > 0 {
                swipes += 1
            } else {
                swipes = 0
                sequenceStartTime = now
                ticksInSequence = 0
            }
            consecutiveTicks = 0
            gapWindow.removeAll(keepingCapacity: true)
        } else {
            consecutiveTicks += 1
            gapWindow.append(rawGap)
            if gapWindow.count > 3 { gapWindow.removeFirst() }
        }

        // Free-spinning wheels never pause between "swipes"; credit fractional swipes instead so
        // fast scroll still engages after ~a wheel-turn of continuous ticks.
        if Double(consecutiveTicks) >= TickAnalyzer.freeSpinTicksPerSwipe {
            swipes += 1.0 / TickAnalyzer.freeSpinTicksPerSwipe
        }

        lastTickTime = now

        let smoothedGap: Double
        if consecutiveTicks == 0 {
            smoothedGap = ScrollTuning.tickIntervalMax // single/slow ticks sit at the curve floor
        } else {
            smoothedGap = min(gapWindow.reduce(0, +) / Double(gapWindow.count),
                              ScrollTuning.tickIntervalMax)
        }

        return Result(tickHz: 1.0 / smoothedGap,
                      swipes: swipes,
                      isSequenceStart: consecutiveTicks == 0 && swipes == 0)
    }
}

/// Quadratic bezier through (0,0) → p1 → (1,1) on normalized time/distance, used as the glide's
/// gesture portion. p1 sits `speedSmoothing` along the unit vector of the current speed, which
/// makes the curve's initial slope equal the running glide speed — the "speed smoothing" that
/// removes per-notch velocity jumps.
struct SpeedBezier {
    let p1x: Double
    let p1y: Double

    /// `v0` in normalized units: (px/s) · duration / distance. 0 → pure ease-in from rest.
    init(normalizedInitialSpeed v0: Double, smoothing: Double) {
        // A non-finite incoming speed (a glide sampled at exactly t = 0, or normalized against a
        // vanishing distance) would leave p1y = ∞/∞ = NaN and poison every sample of the curve.
        // Falling back to rest is the right degradation: no speed to smooth into.
        let v0 = v0.isFinite ? v0 : 0
        // Direction of the current speed in normalized coords: dx ∝ 1, dy ∝ v0.
        let norm = (1 + v0 * v0).squareRoot()
        p1x = smoothing * (1 / norm)
        p1y = smoothing * (v0 / norm)
    }

    func x(atT t: Double) -> Double { t * (2 * p1x * (1 - t) + t) }
    func y(atT t: Double) -> Double { t * (2 * p1y * (1 - t) + t) }

    /// dy/dx — the normalized speed at parameter t.
    func slope(atT t: Double) -> Double {
        let dx = 2 * p1x + 2 * t * (1 - 2 * p1x)
        let dy = 2 * p1y + 2 * t * (1 - 2 * p1y)
        // dx vanishes only at t == 0 with p1x == 0, i.e. a profile with no speed smoothing
        // (Snappy, Precise, Quick — three of the five). The true limit of dy/dx as t → 0 is
        // (1 − 2·p1y)/(1 − 2·p1x) = 1 there, NOT infinity: p1x == 0 implies p1y == 0, since both
        // are the same `smoothing` factor. Returning infinity made `HybridPlan.speed(at: 0)`
        // infinite, and that value is fed straight back as the next notch's initial speed.
        guard dx != 0 else { return (1 - 2 * p1y) / (1 - 2 * p1x) }
        return dy / dx
    }

    /// Analytic t-from-x for the quadratic (p1x < 0.5 keeps x monotonic), clamped to [0, 1].
    func t(atX x: Double) -> Double {
        let a = 1 - 2 * p1x
        let t = abs(a) < 1e-12
            ? x // p1x == 0.5 → x(t) = t
            : (-p1x + (p1x * p1x + a * x).squareRoot()) / a
        return min(max(t, 0), 1)
    }

    /// y as a function of x.
    func y(atX x: Double) -> Double { y(atT: t(atX: x)) }
}

/// Closed-form drag decay v' = −a·v^b from `v0` down to `stopSpeed` (b ≠ 1, 2 —  High uses 0.7).
/// distance(t) = (v0^{2−b} − v(t)^{2−b}) / (a(2−b)),  v(t) = (v0^{1−b} − a(1−b)t)^{1/(1−b)}.
struct DragSegment {
    let a: Double
    let b: Double
    let v0: Double
    let vStop: Double
    let duration: Double
    let distance: Double

    /// From an initial speed: coast from `v0` until decayed to `stopSpeed`.
    init?(initialSpeed v0: Double, a: Double, b: Double, stopSpeed: Double) {
        guard v0 > stopSpeed else { return nil }
        self.a = a; self.b = b; self.v0 = v0; self.vStop = stopSpeed
        duration = (pow(v0, 1 - b) - pow(stopSpeed, 1 - b)) / (a * (1 - b))
        distance = (pow(v0, 2 - b) - pow(stopSpeed, 2 - b)) / (a * (2 - b))
    }

    /// From a target distance: solve the v0 whose full decay covers exactly `distance` px
    /// (fallback when the incoming speed already out-coasts the requested distance).
    ///
    /// The solved v0 is nudged strictly above `stopSpeed` before delegating: for a vanishing
    /// distance it lands exactly ON stopSpeed, which the failable initializer rejects — and this
    /// initializer force-unwraps it. Today every caller passes a distance of at least a few px so
    /// it never triggers, but that is a property of the tuning constants, not of this code, and a
    /// profile with a smaller sensitivity floor or a higher stop speed would turn it into a crash.
    /// Clamping degenerates into a zero-length coast instead.
    init(distance: Double, a: Double, b: Double, stopSpeed: Double) {
        let solved = pow(max(distance, 0) * a * (2 - b) + pow(stopSpeed, 2 - b), 1 / (2 - b))
        let floor = stopSpeed.nextUp
        self.init(initialSpeed: solved.isFinite ? max(solved, floor) : floor,
                  a: a, b: b, stopSpeed: stopSpeed)!
    }

    func speed(at t: Double) -> Double {
        let core = pow(v0, 1 - b) - a * (1 - b) * t
        let stopCore = pow(vStop, 1 - b)
        // core runs from pow(v0, 1−b) to stopCore: downward for b < 1, upward for b > 1 (the
        // exponent 1/(1−b) flips sign with it). Clamp at stopCore either way for t ≥ duration.
        return pow(b < 1 ? max(core, stopCore) : min(core, stopCore), 1 / (1 - b))
    }

    func distance(at t: Double) -> Double {
        guard t < duration else { return distance }
        return (pow(v0, 2 - b) - pow(speed(at: t), 2 - b)) / (a * (2 - b))
    }
}

/// One glide: bezier gesture portion (up to the transition point) + drag coast, covering exactly
/// `total` px in `duration` s. Rebuilt on every wheel notch with the then-current speed.
struct HybridPlan {
    let total: Double            // px, > 0
    let duration: Double         // s
    let transitionTime: Double   // s — bezier portion ends here
    let transitionDistance: Double
    private let bezier: SpeedBezier?
    private let bezierDuration: Double // full (unclipped) bezier time scale
    private let drag: DragSegment?
    private let scale: Double          // total / raw curve end — the transition search stops within
                                       // a distance epsilon; normalizing makes the end land exactly

    /// - Parameters:
    ///   - distance: px to cover (> 0)
    ///   - initialSpeed: current glide speed in px/s (≥ 0); the plan starts at this speed
    ///   - profile: curve shape (base duration, speed smoothing, drag, stop speed)
    init(distance: Double, initialSpeed: Double, profile: ScrollProfile = .balanced) {
        let baseDuration = profile.baseMsPerStep
        let smoothing = profile.speedSmoothing
        let dragCoefficient = profile.dragCoefficient
        let dragExponent = profile.dragExponent
        let stopSpeed = profile.stopSpeed

        total = distance
        bezierDuration = baseDuration
        let curve = SpeedBezier(normalizedInitialSpeed: initialSpeed * baseDuration / distance,
                                   smoothing: smoothing)

        // Combined distance if the drag tail is attached at bezier parameter t: the bezier covers
        // y(t)·distance, then the drag coasts from the speed at t.
        func speedAt(_ t: Double) -> Double { curve.slope(atT: t) * distance / baseDuration }
        func combined(_ t: Double) -> Double {
            let base = curve.y(atT: t) * distance
            guard let d = DragSegment(initialSpeed: speedAt(t), a: dragCoefficient,
                                         b: dragExponent, stopSpeed: stopSpeed) else { return base }
            return base + d.distance
        }

        // Find the latest attachment point where bezier + drag covers exactly `distance`:
        // coarse scan from t=1 downward, then bisection ( BezierHybridCurve).
        let epsilon = 0.2
        var t: Double? = nil
        var lo = 0.0, hi = 1.0
        var bracketed = false
        for k in 0...10 {
            let tk = 1.0 - Double(k) / 10.0
            let c = combined(tk)
            if abs(c - distance) < epsilon { t = tk; break }
            if c <= distance { lo = tk; hi = tk + 0.1; bracketed = true; break }
        }
        if t == nil, bracketed {
            for _ in 0..<64 {
                let mid = (lo + hi) / 2
                let c = combined(mid)
                if abs(c - distance) < epsilon { t = mid; break }
                if c < distance { lo = mid } else { hi = mid }
            }
            if t == nil { t = (lo + hi) / 2 }
        }

        if let t {
            let exitSpeed = speedAt(t)
            let dragSeg = DragSegment(initialSpeed: exitSpeed, a: dragCoefficient,
                                         b: dragExponent, stopSpeed: stopSpeed)
            bezier = curve
            transitionTime = curve.x(atT: t) * baseDuration
            transitionDistance = curve.y(atT: t) * distance
            drag = dragSeg
            duration = transitionTime + (dragSeg?.duration ?? 0)
            let rawEnd = transitionDistance + (dragSeg?.distance ?? 0)
            scale = rawEnd > 0 ? distance / rawEnd : 1
        } else {
            // Even attaching at t=0 over-coasts (huge incoming speed, small distance): drag-only
            // plan that covers exactly `distance`. The incoming speed is dropped, like .
            let coast = HybridPlan.coast(distance: distance, profile: profile)
            bezier = nil
            transitionTime = 0
            transitionDistance = 0
            drag = coast.drag
            duration = coast.drag.duration
            scale = coast.scale
        }
    }

    /// Pure coast: a drag-only plan covering exactly `distance`, starting at the one speed whose
    /// decay to `stopSpeed` spans it (so the start speed is never higher than any glide that
    /// would over-coast the distance). The full init falls back to this when the bezier can't
    /// attach; the ceiling tail uses it directly — unlike the full init, the start speed is
    /// independent of speed smoothing, so a smoothing-0 profile (Snappy/Precise/Quick) gets the
    /// same continuous hand-off.
    init(coastDistance distance: Double, profile: ScrollProfile) {
        let coast = HybridPlan.coast(distance: distance, profile: profile)
        total = distance
        bezier = nil
        bezierDuration = profile.baseMsPerStep
        transitionTime = 0
        transitionDistance = 0
        drag = coast.drag
        duration = coast.drag.duration
        scale = coast.scale
    }

    /// Drag segment + normalization for a drag-only plan (shared by both inits). The scale is
    /// guarded: a degenerate (near-zero) coast would make it infinite, and `distance(at:)` then
    /// evaluates 0 × ∞ = NaN, which propagates into the animator's pixel accumulator and traps
    /// the Int32 conversion in `step`.
    private static func coast(distance: Double, profile: ScrollProfile) -> (drag: DragSegment, scale: Double) {
        let drag = DragSegment(distance: distance, a: profile.dragCoefficient,
                               b: profile.dragExponent, stopSpeed: profile.stopSpeed)
        return (drag, drag.distance > 0 ? distance / drag.distance : 1)
    }

    /// Distance covered `t` seconds in (monotonic, distance(duration) == total).
    func distance(at t: Double) -> Double {
        if t >= duration { return total }
        if t <= transitionTime, let bezier {
            return bezier.y(atX: t / bezierDuration) * total * scale
        }
        guard let drag else { return total }
        return (transitionDistance + drag.distance(at: t - transitionTime)) * scale
    }

    /// Instantaneous speed (px/s) — feeds the next notch's speed smoothing.
    func speed(at t: Double) -> Double {
        if t >= duration { return 0 }
        if t <= transitionTime, let bezier {
            return bezier.slope(atT: bezier.t(atX: t / bezierDuration)) * total * scale / bezierDuration
        }
        guard let drag else { return 0 }
        return drag.speed(at: t - transitionTime) * scale
    }

    /// True once `t` is past the bezier portion — the coast that gets labeled as momentum.
    func inDragPhase(at t: Double) -> Bool { t > transitionTime }
}
