import ApplicationServices
import AppKit
import CoreGraphics

/// Thin wrapper over the Accessibility (AX) trust API. A mouse event tap requires this permission.
enum AccessibilityPermission {

    /// Whether the app currently has Accessibility permission.
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Ask the system to prompt the user for permission (no-op if already granted).
    @discardableResult
    static func request() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Open System Settings directly to the Accessibility pane.
    static func openSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}

/// Input Monitoring is a separate TCC permission from Accessibility. Mousse's active mouse tap
/// works with Accessibility alone, but on some macOS releases a missing Input Monitoring grant
/// looks identical to a dead tap — so its state is shown in Settings for diagnosis, never gated on.
enum InputMonitoringPermission {
    static var isTrusted: Bool { CGPreflightListenEventAccess() }

    @discardableResult
    static func request() -> Bool { CGRequestListenEventAccess() }

    static func openSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
        NSWorkspace.shared.open(url)
    }
}
