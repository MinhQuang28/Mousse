import CoreGraphics
import QuartzCore

/// Pixel span (points) of the display under a point — feeds screen-size sensitivity scaling and
/// the quick-scroll window size. Tap-thread only, like `CursorAppResolver`, so no locking.
///
/// `CGGetDisplaysWithPoint` + `CGDisplayPixelsHigh/Wide` cost ~16 µs per call — the single
/// largest remaining cost per wheel notch on the tap thread — for an answer that only changes
/// when the cursor crosses to another display or the display configuration changes. Cache the
/// display's bounds and both spans: a hit is a rect-containment test. The engine flushes the
/// cache on the same events that flush the cursor-app cache (wake, display change, Space/app
/// switch); the TTL is only a safety net for a display change that arrives without one.
final class ScreenSpanResolver {

    private var bounds = CGRect.null
    private var wide = 0.0
    private var high = 0.0
    private var cachedAt = 0.0
    private let ttl = 5.0 // s

    /// Drop the cached display so the next query re-resolves.
    func invalidate() {
        cachedAt = 0
    }

    /// Span of the display under `point` along the requested axis. Falls back to the 1080p
    /// baseline when no display contains the point (mid-unplug, cursor query failed).
    func span(at point: CGPoint, vertical: Bool) -> Double {
        let now = CACurrentMediaTime()
        if now - cachedAt >= ttl || !bounds.contains(point) {
            guard resolve(point) else { return vertical ? 1080 : 1920 }
            cachedAt = now
        }
        return vertical ? high : wide
    }

    private func resolve(_ point: CGPoint) -> Bool {
        var display: CGDirectDisplayID = 0
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(point, 1, &display, &count) == .success, count > 0 else {
            bounds = .null
            return false
        }
        bounds = CGDisplayBounds(display)
        wide = Double(CGDisplayPixelsWide(display))
        high = Double(CGDisplayPixelsHigh(display))
        return true
    }
}
