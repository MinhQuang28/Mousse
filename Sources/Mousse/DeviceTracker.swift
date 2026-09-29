import Foundation
import IOKit.hid
import os

/// One connected pointing device, as the Devices settings tab lists it.
struct HIDDeviceInfo: Identifiable, Equatable, Sendable {
    let key: String   // vendor:product — the `DeviceProfile.id` it maps to
    let name: String
    var id: String { key }

    static func key(vendorID: Int, productID: Int) -> String {
        String(format: "%04x:%04x", vendorID, productID)
    }
}

/// Attributes scroll input to a physical mouse, for per-device scroll profiles.
///
/// A CGEvent carries no public device identity, so (like LinearMouse) we watch the HID layer in
/// parallel: every non-zero wheel / horizontal-pan value marks its device as the ACTIVE scroll
/// device, and the tap applies that device's profile to the scroll events it sees. The two paths
/// aren't ordered relative to each other, so the very first event after switching mice may still
/// get the previous mouse's settings — every later one is right. Reading HID input values needs
/// the Input Monitoring permission; without it `activeDeviceKey()` stays nil and every device
/// uses the global settings (the same as having no profiles).
///
/// Lifecycle: runs only while a profile exists or the Devices tab is open, and stops otherwise.
/// Each run is a `Session` (its own thread + run loop + HID manager), so a stop followed by a
/// quick restart never shares state between the old and new thread. If the manager could not be
/// opened (Input Monitoring missing), the permission is re-checked every 2 s and the session
/// restarted once it is granted — no relaunch needed.
///
/// Threading: wheel values arrive at up to the device's report rate on the session thread —
/// never on the main thread. `activeKey` is read by the tap thread under `lock`; `connected` is
/// published on the main thread for SwiftUI.
final class DeviceTracker: ObservableObject {

    static let shared = DeviceTracker()
    private init() {}

    /// Mice currently connected, deduplicated by key (one mouse often exposes several HID
    /// interfaces), sorted by name. Main thread only.
    @Published private(set) var connected: [HIDDeviceInfo] = []

    // Unfair lock: read by the tap thread on every scroll event, written per wheel HID value.
    private let lock = OSAllocatedUnfairLock()
    private var activeKey: String?

    // Main thread only.
    private var session: DeviceTrackerSession?
    private var hasProfiles = false
    private var tabOpen = false
    private var retryTimer: Timer?

    /// Whether any per-device profile exists (main thread).
    func setHasProfiles(_ value: Bool) {
        hasProfiles = value
        update()
    }

    /// Whether the Devices tab is on screen — it lists mice even before any profile (main thread).
    func setTabOpen(_ value: Bool) {
        tabOpen = value
        update()
    }

    /// Key of the mouse that scrolled most recently, or nil if none is known yet (or Input
    /// Monitoring is not granted). Any thread.
    func activeDeviceKey() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return activeKey
    }

    private func update() {
        if hasProfiles || tabOpen { start() } else { stop() }
    }

    private func start() {
        guard session == nil else { return }
        let s = DeviceTrackerSession(tracker: self)
        session = s
        s.start()
    }

    private func stop() {
        retryTimer?.invalidate()
        retryTimer = nil
        guard let s = session else { return }
        session = nil
        s.stop()
        setActiveKey(nil)
        connected = []
    }

    // MARK: Session callbacks (called by DeviceTrackerSession)

    func sessionOpenFailed(_ s: DeviceTrackerSession) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.session === s, self.retryTimer == nil else { return }
            self.retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                guard let self, InputMonitoringPermission.isTrusted else { return }
                self.stop()
                self.update()
            }
        }
    }

    func publish(_ list: [HIDDeviceInfo], from s: DeviceTrackerSession) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.session === s, self.connected != list else { return }
            self.connected = list
        }
    }

    func setActiveKey(_ key: String?) {
        lock.lock()
        activeKey = key
        lock.unlock()
    }

    /// Forget the active mouse once its last HID interface is gone, so an unplugged mouse's
    /// profile doesn't keep applying to scrolls nothing else claims.
    func deviceGone(_ key: String) {
        lock.lock()
        if activeKey == key { activeKey = nil }
        lock.unlock()
    }
}
