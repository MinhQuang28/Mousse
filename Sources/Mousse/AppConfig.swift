import Foundation

/// How the mouse wheel scrolls.
enum ScrollMode: String, Codable, Sendable, CaseIterable {
    case standard    // OS stepped wheel — raw passthrough; each notch jumps instantly
    case smooth      // trackpad-style eased momentum
    case smoothStep  // Windows-browser style: each notch eases a fixed N-line step, no coast

    var label: String {
        switch self {
        case .standard:   return "Standard (instant)"
        case .smooth:     return "Smooth (trackpad)"
        case .smoothStep: return "Smooth-step (Windows)"
        }
    }
}

/// The scroll knobs that can differ per physical mouse — the same set as the global Scroll tab.
/// A device without a profile uses the global values (`AppConfig.scrollSettings`).
struct ScrollDeviceSettings: Codable, Sendable, Equatable {
    var reverseScroll = false
    var reverseScrollHorizontal = false
    var scrollMode: ScrollMode = .smooth
    var scrollSmoothness: ScrollSmoothness = .balanced
    var scrollSpeed = 0.5
    var scrollLines = 3
    var scrollAcceleration = true
    var smoothHighRes = false
    var zoomSpeed = 1.0

    enum CodingKeys: String, CodingKey {
        case reverseScroll, reverseScrollHorizontal, scrollMode, scrollSmoothness, scrollSpeed
        case scrollLines, scrollAcceleration, smoothHighRes, zoomSpeed
    }

    init() {}

    /// Tolerant like `AppConfig`: a missing or unreadable field keeps its default.
    init(from decoder: Decoder) throws {
        self.init()
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else { return }
        func field<T: Decodable>(_ type: T.Type, _ key: CodingKeys) -> T? {
            (try? c.decodeIfPresent(type, forKey: key)) ?? nil
        }
        reverseScroll      = field(Bool.self, .reverseScroll) ?? reverseScroll
        reverseScrollHorizontal = field(Bool.self, .reverseScrollHorizontal) ?? reverseScroll
        scrollMode         = field(ScrollMode.self, .scrollMode) ?? scrollMode
        scrollSmoothness   = field(ScrollSmoothness.self, .scrollSmoothness) ?? scrollSmoothness
        scrollSpeed        = field(Double.self, .scrollSpeed) ?? scrollSpeed
        scrollLines        = field(Int.self, .scrollLines) ?? scrollLines
        scrollAcceleration = field(Bool.self, .scrollAcceleration) ?? scrollAcceleration
        smoothHighRes      = field(Bool.self, .smoothHighRes) ?? smoothHighRes
        zoomSpeed          = field(Double.self, .zoomSpeed) ?? zoomSpeed
        clampToUIRanges()
    }

    /// Same bounds the Settings UI enforces (see `AppConfig.init(from:)`).
    mutating func clampToUIRanges() {
        scrollSpeed = min(max(scrollSpeed, 0.05), 1.5)
        scrollLines = min(max(scrollLines, 1), 10)
        zoomSpeed   = min(max(zoomSpeed, 0.2), 6.0)
    }
}

/// Per-device scroll override, keyed by the mouse's USB/Bluetooth vendor + product ID — stable
/// across reconnects and ports (two identical mice share one profile).
struct DeviceProfile: Codable, Sendable, Equatable, Identifiable {
    var id: String      // `HIDDeviceInfo.key(vendorID:productID:)`
    var name: String    // product name at the time the profile was created (display only)
    var settings: ScrollDeviceSettings
}

/// A single mouse-button → action mapping.
struct ButtonMapping: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var buttonNumber: Int   // 1-based: 1=left, 2=right, 3=middle, 4/5=side buttons, ...
    var action: RemapAction

    init(id: UUID = UUID(), buttonNumber: Int, action: RemapAction) {
        self.id = id
        self.buttonNumber = buttonNumber
        self.action = action
    }

    // `id` is a UI identity, not user data — regenerate it when absent (e.g. a hand-edited or
    // older config) instead of letting synthesized decoding throw the whole mapping away.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        buttonNumber = try c.decode(Int.self, forKey: .buttonNumber)
        action = try c.decode(RemapAction.self, forKey: .action)
    }
}

/// The whole persisted configuration. Plain Codable value stored as JSON — no keychain,
/// no license, survives rebuilds.
/// `Equatable` so `ConfigStore` can skip the save + engine reload when an assignment changes
/// nothing — see the guard in its `didSet`.
struct AppConfig: Codable, Sendable, Equatable {
    var enabled: Bool = true
    var reverseScroll: Bool = false     // vertical wheel direction
    var reverseScrollHorizontal: Bool = false // horizontal (tilt / side wheel) direction; configs
                                        // written before the split inherit `reverseScroll`
    var scrollMode: ScrollMode = .smooth
    var scrollSmoothness: ScrollSmoothness = .balanced // Smooth mode curve profile (derived)
    var scrollSpeed: Double = 0.5       // 0.05 (slowest) … 1.5 (fast); Smooth mode:  sensitivity
                                        // anchors (0=low, 0.5=medium, 1=high); also scales hi-res gain
    var scrollLines: Int = 3            // lines per notch in Smooth-step mode (Windows default = 3)
    var scrollAcceleration: Bool = true // rapid consecutive notches scroll farther (Smooth mode only)
    var smoothHighRes: Bool = false     // also smooth high-res "continuous" mice (e.g. Keychron M6) that
                                        // lack a flywheel; keep off for MX-Master-style free-spin mice
    var zoomSpeed: Double = 1.0         // ⌘+wheel pinch sensitivity multiplier, independent of scrollSpeed
    var spaceDragButton: Int = 0        // 0 = off; else button held to drag-switch Spaces
    var spaceDragThreshold: Double = 200 // pixels of horizontal drag per Space switch (discrete mode)
    var spaceDragReverse: Bool = false  // flip drag direction ↔ Space direction
    var spaceDragLockPointer: Bool = false // pin the pointer in place while drag-switching
    var spaceDragFollowFinger: Bool = true // drive the real Space-slide (trackpad-like) when the
                                           // OS supports it; off = discrete one-jump-per-distance
    var excludedBundleIDs: [String] = [] // apps where scroll smoothing is bypassed (wheel stays
                                         // native, so AppKit's vertical→horizontal transposition for
                                         // horizontal-only views — e.g. Nimble Commander — still works)
    var verticalToHorizontalBundleIDs: [String] = [] // apps where the scroll axes are SWAPPED (the
                                         // wheel scrolls horizontally): purpose-built for
                                         // horizontal-first browsers like Nimble Commander's Brief
                                         // panels — smoothing stays on, we transpose ourselves
    var mappings: [ButtonMapping] = AppConfig.defaultMappings
    var deviceProfiles: [DeviceProfile] = [] // per-mouse scroll overrides (need Input Monitoring)

    /// The global scroll settings as one value — what a device without a profile uses, and the
    /// seed for a new profile. Bindable (`$store.config.scrollSettings`) so the global Scroll tab
    /// and the per-device editor share one view.
    var scrollSettings: ScrollDeviceSettings {
        get {
            var s = ScrollDeviceSettings()
            s.reverseScroll = reverseScroll
            s.reverseScrollHorizontal = reverseScrollHorizontal
            s.scrollMode = scrollMode
            s.scrollSmoothness = scrollSmoothness
            s.scrollSpeed = scrollSpeed
            s.scrollLines = scrollLines
            s.scrollAcceleration = scrollAcceleration
            s.smoothHighRes = smoothHighRes
            s.zoomSpeed = zoomSpeed
            return s
        }
        set {
            reverseScroll = newValue.reverseScroll
            reverseScrollHorizontal = newValue.reverseScrollHorizontal
            scrollMode = newValue.scrollMode
            scrollSmoothness = newValue.scrollSmoothness
            scrollSpeed = newValue.scrollSpeed
            scrollLines = newValue.scrollLines
            scrollAcceleration = newValue.scrollAcceleration
            smoothHighRes = newValue.smoothHighRes
            zoomSpeed = newValue.zoomSpeed
        }
    }

    /// Sensible defaults so the app is useful on first launch.
    static let defaultMappings: [ButtonMapping] = [
        ButtonMapping(buttonNumber: 4, action: .spaceLeft),
        ButtonMapping(buttonNumber: 5, action: .spaceRight),
    ]
}

/// Tolerant decoding: a missing key OR an unreadable value (type mismatch, unknown enum case —
/// e.g. a config written by a newer app version) falls back to that field's default instead of
/// throwing, so one bad value never wipes the whole saved config. Mappings degrade per element:
/// a broken mapping is dropped, the rest survive. Encoding stays synthesized.
extension AppConfig {
    enum CodingKeys: String, CodingKey {
        case enabled, reverseScroll, reverseScrollHorizontal, scrollMode, scrollSmoothness, smoothScroll, scrollSpeed, scrollLines
        case scrollAcceleration, smoothHighRes, zoomSpeed
        case spaceDragButton, spaceDragThreshold, spaceDragReverse, spaceDragFollowFinger
        case spaceDragLockPointer
        case excludedBundleIDs, verticalToHorizontalBundleIDs, mappings, deviceProfiles
    }

    /// Contains an element's decode failure to that element instead of failing the whole array.
    private struct Lossy<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: Decoder) { value = try? T(from: decoder) }
    }

    init(from decoder: Decoder) throws {
        self.init()
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else { return }
        // `try?` (not just decodeIfPresent) so a present-but-invalid value also falls back.
        func field<T: Decodable>(_ type: T.Type, _ key: CodingKeys) -> T? {
            (try? c.decodeIfPresent(type, forKey: key)) ?? nil
        }
        enabled            = field(Bool.self,   .enabled)            ?? enabled
        reverseScroll      = field(Bool.self,   .reverseScroll)      ?? reverseScroll
        // Before the per-axis split, `reverseScroll` flipped both axes — keep that for old configs.
        reverseScrollHorizontal = field(Bool.self, .reverseScrollHorizontal) ?? reverseScroll
        // Prefer scrollMode; fall back to the legacy `smoothScroll` bool if that's all we have.
        if let mode = field(ScrollMode.self, .scrollMode) {
            scrollMode = mode
        } else if let legacy = field(Bool.self, .smoothScroll) {
            scrollMode = legacy ? .smooth : .standard
        }
        scrollSmoothness   = field(ScrollSmoothness.self, .scrollSmoothness) ?? scrollSmoothness
        scrollSpeed        = field(Double.self, .scrollSpeed)        ?? scrollSpeed
        scrollLines        = field(Int.self,    .scrollLines)        ?? scrollLines
        scrollAcceleration = field(Bool.self,   .scrollAcceleration) ?? scrollAcceleration
        smoothHighRes      = field(Bool.self,   .smoothHighRes)      ?? smoothHighRes
        zoomSpeed          = field(Double.self, .zoomSpeed)          ?? zoomSpeed
        spaceDragButton    = field(Int.self,    .spaceDragButton)    ?? spaceDragButton
        spaceDragThreshold = field(Double.self, .spaceDragThreshold) ?? spaceDragThreshold
        spaceDragReverse   = field(Bool.self,   .spaceDragReverse)   ?? spaceDragReverse
        spaceDragFollowFinger = field(Bool.self, .spaceDragFollowFinger) ?? spaceDragFollowFinger
        spaceDragLockPointer = field(Bool.self, .spaceDragLockPointer) ?? spaceDragLockPointer
        excludedBundleIDs  = field([String].self, .excludedBundleIDs) ?? excludedBundleIDs
        verticalToHorizontalBundleIDs = field([String].self, .verticalToHorizontalBundleIDs) ?? verticalToHorizontalBundleIDs
        mappings           = field([Lossy<ButtonMapping>].self, .mappings)?.compactMap(\.value) ?? mappings
        // Lossy per profile, and one profile per device (first wins, like button mappings).
        var seenDevices = Set<String>()
        deviceProfiles     = (field([Lossy<DeviceProfile>].self, .deviceProfiles)?.compactMap(\.value) ?? [])
            .filter { seenDevices.insert($0.id).inserted }

        // Range-clamp the numeric fields to the same bounds the Settings UI enforces. Only a
        // hand-edited config can stray (the UI can't), but the failure modes are silent and odd:
        // scrollLines 0 makes Smooth-step scroll nothing and a negative value reverses it, while
        // an out-of-range scrollSpeed extrapolates the sensitivity anchors linearly without limit.
        // (JSONDecoder rejects NaN/Inf on its own, so finiteness needs no check here.)
        scrollSpeed        = min(max(scrollSpeed, 0.05), 1.5)
        scrollLines        = min(max(scrollLines, 1), 10)
        zoomSpeed          = min(max(zoomSpeed, 0.2), 6.0)
        spaceDragThreshold = min(max(spaceDragThreshold, 100), 400)
    }

    // Custom encode because `smoothScroll` is a decode-only legacy key with no backing property.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(reverseScroll, forKey: .reverseScroll)
        try c.encode(reverseScrollHorizontal, forKey: .reverseScrollHorizontal)
        try c.encode(scrollMode, forKey: .scrollMode)
        try c.encode(scrollSmoothness, forKey: .scrollSmoothness)
        try c.encode(scrollSpeed, forKey: .scrollSpeed)
        try c.encode(scrollLines, forKey: .scrollLines)
        try c.encode(scrollAcceleration, forKey: .scrollAcceleration)
        try c.encode(smoothHighRes, forKey: .smoothHighRes)
        try c.encode(zoomSpeed, forKey: .zoomSpeed)
        try c.encode(spaceDragButton, forKey: .spaceDragButton)
        try c.encode(spaceDragThreshold, forKey: .spaceDragThreshold)
        try c.encode(spaceDragReverse, forKey: .spaceDragReverse)
        try c.encode(spaceDragFollowFinger, forKey: .spaceDragFollowFinger)
        try c.encode(spaceDragLockPointer, forKey: .spaceDragLockPointer)
        try c.encode(excludedBundleIDs, forKey: .excludedBundleIDs)
        try c.encode(verticalToHorizontalBundleIDs, forKey: .verticalToHorizontalBundleIDs)
        try c.encode(mappings, forKey: .mappings)
        try c.encode(deviceProfiles, forKey: .deviceProfiles)
    }
}
