import Foundation
import IOKit.hid
import os

/// One run of `DeviceTracker`'s HID watcher: owns its thread, run loop, manager and device table.
final class DeviceTrackerSession {
    private unowned let tracker: DeviceTracker
    private let lock = OSAllocatedUnfairLock()
    private var runLoop: CFRunLoop? // guarded by `lock`
    private var stopped = false     // guarded by `lock`

    // Session thread only.
    private var infoByDevice: [UnsafeMutableRawPointer: HIDDeviceInfo] = [:]

    init(tracker: DeviceTracker) { self.tracker = tracker }

    func start() {
        let t = Thread { [self] in run() } // the thread retains the session until it exits
        t.name = "com.mousse.device-tracker"
        t.qualityOfService = .userInteractive
        t.start()
    }

    /// Ends the run loop; the session thread then closes the manager and exits. Any thread.
    func stop() {
        lock.lock()
        stopped = true
        let rl = runLoop
        lock.unlock()
        guard let rl else { return } // not running yet: `run()` sees `stopped` and bails out
        // A queued block, not a bare CFRunLoopStop: the latter is lost if the thread hasn't
        // entered CFRunLoopRun yet, while the block waits for it.
        CFRunLoopPerformBlock(rl, CFRunLoopMode.defaultMode.rawValue) { CFRunLoopStop(CFRunLoopGetCurrent()) }
        CFRunLoopWakeUp(rl)
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
            Unmanaged<DeviceTrackerSession>.fromOpaque(context).takeUnretainedValue().deviceAdded(device)
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(mgr, { context, _, _, device in
            guard let context else { return }
            Unmanaged<DeviceTrackerSession>.fromOpaque(context).takeUnretainedValue().deviceRemoved(device)
        }, ctx)
        IOHIDManagerRegisterInputValueCallback(mgr, { context, _, _, value in
            guard let context else { return }
            Unmanaged<DeviceTrackerSession>.fromOpaque(context).takeUnretainedValue().inputValue(value)
        }, ctx)

        let rl = CFRunLoopGetCurrent()!
        lock.lock()
        if stopped { lock.unlock(); return }
        runLoop = rl
        lock.unlock()

        IOHIDManagerScheduleWithRunLoop(mgr, rl, CFRunLoopMode.defaultMode.rawValue)
        let opened = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        if opened != kIOReturnSuccess {
            NSLog("Mousse: device tracker IOHIDManagerOpen failed (0x%X) — per-device profiles inactive until Input Monitoring is granted", opened)
            tracker.sessionOpenFailed(self)
        }
        // A bare port keeps the run loop alive even with no device attached yet.
        RunLoop.current.add(NSMachPort(), forMode: .default)
        CFRunLoopRun()

        IOHIDManagerUnscheduleFromRunLoop(mgr, rl, CFRunLoopMode.defaultMode.rawValue)
        if opened == kIOReturnSuccess { IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone)) }
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
        guard let gone = infoByDevice.removeValue(forKey: Unmanaged.passUnretained(device).toOpaque())
        else { return }
        if !infoByDevice.values.contains(where: { $0.key == gone.key }) { tracker.deviceGone(gone.key) }
        publish()
    }

    private func inputValue(_ value: IOHIDValue) {
        guard IOHIDValueGetIntegerValue(value) != 0 else { return } // idle reports carry 0
        let device = IOHIDElementGetDevice(IOHIDValueGetElement(value))
        tracker.setActiveKey(info(for: device).key)
    }

    private func publish() {
        var seen = Set<String>()
        let list = infoByDevice.values
            .filter { seen.insert($0.key).inserted }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        tracker.publish(list, from: self)
    }
}
