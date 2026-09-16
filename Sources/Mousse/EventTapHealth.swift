import Foundation

/// Coarse state of the mouse event tap, derived from engine flags. Pure so it is unit-testable;
/// the engine feeds it a locked snapshot and Settings shows the result.
enum EventTapHealth: Equatable, Sendable {
    case waitingForPermission
    case initializing
    case healthy
    case recovering
    case failed

    static func resolve(accessibilityTrusted: Bool, hasTap: Bool, tapEnabled: Bool,
                        rebuildPending: Bool, creationFailed: Bool,
                        lastRecoveryAt: Date?, now: Date) -> EventTapHealth {
        guard accessibilityTrusted else { return .waitingForPermission }
        if creationFailed { return .failed }
        guard hasTap else { return .initializing }
        if rebuildPending { return .recovering }
        // A tap that just came back is still "recovering" for a beat, so a rebuild storm is
        // visible in Settings instead of flickering healthy between rebuilds.
        let recentlyRecovered = lastRecoveryAt.map { now.timeIntervalSince($0) < 2 } ?? false
        return tapEnabled && !recentlyRecovered ? .healthy : .recovering
    }

    var label: String {
        switch self {
        case .waitingForPermission: return "Waiting for Accessibility"
        case .initializing: return "Starting…"
        case .healthy: return "Healthy"
        case .recovering: return "Recovering…"
        case .failed: return "Failed — retrying"
        }
    }
}

/// What the engine reports about its tap for the Settings window.
struct EventTapStatus: Equatable, Sendable {
    let health: EventTapHealth
    let recoveryCount: Int
    let lastRecoveryAt: Date?
}
