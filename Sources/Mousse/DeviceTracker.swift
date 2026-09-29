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
/// Threading: the HID manager runs on its own thread + run loop (wheel values arrive at up to the
/// device's report rate — never on the main thread). `activeKey` is read by the tap thread under
/// `lock`; `connected` is published on the main thread for SwiftUI.
final class DeviceTracker: ObservableObject {

    static let shared = DeviceTracker()
    private init() {}

    /// Mice currently connected, deduplicated by key (one mouse often exposes several HID
    /// interfaces), sorted by name. Main thread only.
    @Published private(set) var connected: [HIDDeviceInfo] = []

    // Unfair lock: read by the tap thread on every scroll event, written per wheel HID value.
    private let lock = OSAllocatedUnfairLock()
    private var activeKey: String?

    // Tracker thread only.
    private var infoByDevice: [UnsafeMutableRawPointer: HIDDeviceInfo] = [:]
    private var manager: IOHIDManager?

    // Main thread only.
    private var thread: Thread?

    /// Start watching (idempotent; main thread).
    func start() {
        guard thread == nil else { return }
        let t = Thread { [weak self] in self?.run() }
        t.name = "com.mousse.device-tracker"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    /// Key of the mouse that scrolled most recently, or nil if none is known yet (or Input
    /// Monitoring is not granted). Any thread.
    func activeDeviceKey() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return activeKey
    }

    private func run() {
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let devices: [[String: Any]] = [
            [kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop,
             kIOHIDDeviceUsageKey as String: kHIDUsage_GD_Mouse],
            [kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop,
             kIOHIDDeviceUsageKey as String: kHIDUsage_GD_Pointer],
        ]
        IOHIDManagerSetDeviceMatchingMultiple(mgr, devices as CFArray)
        // Only the scroll elements: pointer motion would wake this thread at the full report
        // rate for nothing (profiles are scroll-only).
        let values: [[String: Any]] = [
            [kIOHIDElementUsagePageKey as String: kHIDPage_GenericDesktop,
             kIOHIDElementUsageKey as String: kHIDUsage_GD_Wheel],
            [kIOHIDElementUsagePageKey as String: kHIDPage_Consumer,
             kIOHIDElementUsageKey as String: kHIDUsage_Csmr_ACPan],
        ]
        IOHIDManagerSetInputValueMatchingMultiple(mgr, values as CFArray)

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(mgr, { context, _, _, device in
            guard let context else { return }
            Unmanaged<DeviceTracker>.fromOpaque(context).takeUnretainedValue().deviceAdded(device)
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(mgr, { context, _, _, device in
            guard let context else { return }
            Unmanaged<DeviceTracker>.fromOpaque(context).takeUnretainedValue().deviceRemoved(device)
        }, ctx)
        IOHIDManagerRegisterInputValueCallback(mgr, { context, _, _, value in
            guard let context else { return }
            Unmanaged<DeviceTracker>.fromOpaque(context).takeUnretainedValue().inputValue(value)
        }, ctx)
        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        let opened = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        if opened != kIOReturnSuccess {
            NSLog("Mousse: device tracker IOHIDManagerOpen failed (0x%X) — per-device profiles inactive", opened)
        }
        manager = mgr
        // A bare port keeps the run loop alive even with no device attached yet.
        RunLoop.current.add(NSMachPort(), forMode: .default)
        CFRunLoopRun()
    }

    private func info(for device: IOHIDDevice) -> HIDDeviceInfo {
        let ptr = Unmanaged.passUnretained(device).toOpaque()
        if let known = infoByDevice[ptr] { return known }
        func intProp(_ key: String) -> Int {
            (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue ?? 0
        }
        let vendor = intProp(kIOHIDVendorIDKey)
        let product = intProp(kIOHIDProductIDKey)
        let name = (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String)
            .flatMap { $0.isEmpty ? nil : $0 } ?? "Mouse \(HIDDeviceInfo.key(vendorID: vendor, productID: product))"
        let info = HIDDeviceInfo(key: HIDDeviceInfo.key(vendorID: vendor, productID: product), name: name)
        infoByDevice[ptr] = info
        return info
    }

    private func deviceAdded(_ device: IOHIDDevice) {
        _ = info(for: device)
        publish()
    }

    private func deviceRemoved(_ device: IOHIDDevice) {
        infoByDevice[Unmanaged.passUnretained(device).toOpaque()] = nil
        publish()
    }

    private func inputValue(_ value: IOHIDValue) {
        guard IOHIDValueGetIntegerValue(value) != 0 else { return } // idle reports carry 0
        let device = IOHIDElementGetDevice(IOHIDValueGetElement(value))
        let key = info(for: device).key
        lock.lock()
        activeKey = key
        lock.unlock()
    }

    private func publish() {
        var seen = Set<String>()
        let list = infoByDevice.values
            .filter { seen.insert($0.key).inserted }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        DispatchQueue.main.async { [weak self] in
            if self?.connected != list { self?.connected = list }
        }
    }
}
