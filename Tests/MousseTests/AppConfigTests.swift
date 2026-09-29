import XCTest
@testable import Mousse

/// Guards the persisted-config contract: round-trips, tolerant decoding (a missing key OR an
/// invalid value must fall back to that field's default, never throw — throwing would wipe the
/// user's saved settings), and the legacy `smoothScroll` bool → `ScrollMode` bridge.
final class AppConfigTests: XCTestCase {

    private func roundTrip(_ config: AppConfig) throws -> AppConfig {
        let data = try JSONEncoder().encode(config)
        return try JSONDecoder().decode(AppConfig.self, from: data)
    }

    func testDefaultsRoundTrip() throws {
        let decoded = try roundTrip(AppConfig())
        XCTAssertEqual(decoded.enabled, true)
        XCTAssertEqual(decoded.scrollMode, .smooth)
        XCTAssertEqual(decoded.scrollSpeed, 0.5, accuracy: 1e-9)
        XCTAssertEqual(decoded.scrollLines, 3)
        XCTAssertEqual(decoded.scrollAcceleration, true)
        XCTAssertEqual(decoded.smoothHighRes, false)
        XCTAssertEqual(decoded.reverseScroll, false)
        XCTAssertEqual(decoded.mappings.count, AppConfig.defaultMappings.count)
    }

    func testNonDefaultValuesPersist() throws {
        var config = AppConfig()
        config.enabled = false
        config.reverseScroll = true
        config.scrollMode = .smoothStep
        config.scrollSpeed = 1.3
        config.scrollLines = 7
        config.scrollAcceleration = false
        config.smoothHighRes = true
        config.spaceDragButton = 4
        config.spaceDragThreshold = 250
        config.spaceDragReverse = true
        config.excludedBundleIDs = ["info.filesmanager.Files", "com.example.other"]
        config.verticalToHorizontalBundleIDs = ["info.filesmanager.Files"]
        config.scrollSmoothness = .floaty
        config.mappings = [ButtonMapping(buttonNumber: 6, action: .missionControl)]

        let decoded = try roundTrip(config)
        XCTAssertEqual(decoded.enabled, false)
        XCTAssertEqual(decoded.reverseScroll, true)
        XCTAssertEqual(decoded.scrollMode, .smoothStep)
        XCTAssertEqual(decoded.scrollSpeed, 1.3, accuracy: 1e-9)
        XCTAssertEqual(decoded.scrollLines, 7)
        XCTAssertEqual(decoded.scrollAcceleration, false)
        XCTAssertEqual(decoded.smoothHighRes, true)
        XCTAssertEqual(decoded.spaceDragButton, 4)
        XCTAssertEqual(decoded.spaceDragThreshold, 250, accuracy: 1e-9)
        XCTAssertEqual(decoded.spaceDragReverse, true)
        XCTAssertEqual(decoded.excludedBundleIDs, ["info.filesmanager.Files", "com.example.other"])
        XCTAssertEqual(decoded.verticalToHorizontalBundleIDs, ["info.filesmanager.Files"])
        XCTAssertEqual(decoded.scrollSmoothness, .floaty)
        XCTAssertEqual(decoded.mappings, config.mappings)
    }

    /// An old config saved before a setting existed must decode with that setting at its default,
    /// not throw and reset everything.
    func testMissingKeysFallBackToDefaults() throws {
        let partial = #"{"enabled":false,"reverseScroll":true}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppConfig.self, from: partial)
        XCTAssertEqual(decoded.enabled, false)
        XCTAssertEqual(decoded.reverseScroll, true)
        // Everything absent falls back to defaults.
        XCTAssertEqual(decoded.scrollMode, .smooth)
        XCTAssertEqual(decoded.scrollLines, 3)
        XCTAssertEqual(decoded.smoothHighRes, false)
        XCTAssertEqual(decoded.excludedBundleIDs, [])
        XCTAssertEqual(decoded.verticalToHorizontalBundleIDs, [])
        XCTAssertEqual(decoded.scrollSmoothness, .balanced)
        XCTAssertEqual(decoded.mappings.count, AppConfig.defaultMappings.count)
    }

    func testEmptyObjectDecodesToDefaults() throws {
        let decoded = try JSONDecoder().decode(AppConfig.self, from: #"{}"#.data(using: .utf8)!)
        XCTAssertEqual(decoded.scrollMode, AppConfig().scrollMode)
        XCTAssertEqual(decoded.scrollSpeed, AppConfig().scrollSpeed, accuracy: 1e-9)
    }

    /// Legacy bridge: configs predating `scrollMode` stored a `smoothScroll` bool.
    func testLegacySmoothScrollTrueMapsToSmooth() throws {
        let legacy = #"{"smoothScroll":true}"#.data(using: .utf8)!
        XCTAssertEqual(try JSONDecoder().decode(AppConfig.self, from: legacy).scrollMode, .smooth)
    }

    func testLegacySmoothScrollFalseMapsToStandard() throws {
        let legacy = #"{"smoothScroll":false}"#.data(using: .utf8)!
        XCTAssertEqual(try JSONDecoder().decode(AppConfig.self, from: legacy).scrollMode, .standard)
    }

    /// A present `scrollMode` wins over the legacy bool when both appear.
    func testScrollModeWinsOverLegacyBool() throws {
        let both = #"{"scrollMode":"smoothStep","smoothScroll":false}"#.data(using: .utf8)!
        XCTAssertEqual(try JSONDecoder().decode(AppConfig.self, from: both).scrollMode, .smoothStep)
    }

    // MARK: - Present-but-invalid values (config from a newer app version, or hand-edited)

    /// An unknown enum case resets THAT field only — every other saved setting must survive.
    func testUnknownEnumValueFallsBackWithoutWipingRest() throws {
        let json = #"{"scrollMode":"turbo","enabled":false,"scrollLines":7}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppConfig.self, from: json)
        XCTAssertEqual(decoded.scrollMode, .smooth) // unknown case → default
        XCTAssertEqual(decoded.enabled, false)      // neighbors survive
        XCTAssertEqual(decoded.scrollLines, 7)
    }

    func testWrongTypeValueFallsBackWithoutWipingRest() throws {
        let json = #"{"scrollSpeed":"fast","reverseScroll":true}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppConfig.self, from: json)
        XCTAssertEqual(decoded.scrollSpeed, 0.5, accuracy: 1e-9)
        XCTAssertEqual(decoded.reverseScroll, true)
    }

    /// One broken mapping is dropped; intact ones survive (previously it wiped the whole config).
    func testBrokenMappingElementIsDroppedNotFatal() throws {
        let good = String(data: try JSONEncoder().encode(ButtonMapping(buttonNumber: 4, action: .spaceLeft)),
                          encoding: .utf8)!
        let json = #"{"scrollLines":7,"mappings":[\#(good),{"buttonNumber":5,"action":{"warpDrive":{}}}]}"#
        let decoded = try JSONDecoder().decode(AppConfig.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(decoded.mappings.count, 1)
        XCTAssertEqual(decoded.mappings[0].buttonNumber, 4)
        XCTAssertEqual(decoded.mappings[0].action, .spaceLeft)
        XCTAssertEqual(decoded.scrollLines, 7)
    }

    /// A mapping missing its `id` (hand-edited/older file) keeps the mapping under a fresh id.
    func testMappingWithoutIdIsKept() throws {
        let json = #"{"mappings":[{"buttonNumber":6,"action":{"launchpad":{}}}]}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppConfig.self, from: json)
        XCTAssertEqual(decoded.mappings.count, 1)
        XCTAssertEqual(decoded.mappings[0].buttonNumber, 6)
        XCTAssertEqual(decoded.mappings[0].action, .launchpad)
    }

    /// A structurally wrong file (top level not an object) yields defaults instead of throwing.
    func testNonObjectTopLevelDecodesToDefaults() throws {
        let decoded = try JSONDecoder().decode(AppConfig.self, from: #"[]"#.data(using: .utf8)!)
        XCTAssertEqual(decoded.enabled, AppConfig().enabled)
        XCTAssertEqual(decoded.mappings.count, AppConfig.defaultMappings.count)
    }

    /// Hand-edited out-of-range numbers are clamped to the UI's own bounds on decode:
    /// scrollLines 0 would make Smooth-step scroll nothing (negative would reverse it), and an
    /// out-of-range scrollSpeed extrapolates the sensitivity curve without limit.
    func testOutOfRangeValuesAreClamped() throws {
        let json = #"{"scrollSpeed":99,"scrollLines":-2,"spaceDragThreshold":5}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppConfig.self, from: json)
        XCTAssertEqual(decoded.scrollSpeed, 1.5, accuracy: 1e-9)
        XCTAssertEqual(decoded.scrollLines, 1)
        XCTAssertEqual(decoded.spaceDragThreshold, 100, accuracy: 1e-9)
    }

    /// In-range values pass through the clamp untouched (the bounds match the UI's).
    func testInRangeValuesSurviveClamp() throws {
        let json = #"{"scrollSpeed":0.05,"scrollLines":10,"spaceDragThreshold":400}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppConfig.self, from: json)
        XCTAssertEqual(decoded.scrollSpeed, 0.05, accuracy: 1e-9)
        XCTAssertEqual(decoded.scrollLines, 10)
        XCTAssertEqual(decoded.spaceDragThreshold, 400, accuracy: 1e-9)
    }
}

extension AppConfigTests {
    func testZoomSpeedRoundTripsAndClamps() throws {
        var c = AppConfig()
        c.zoomSpeed = 0.5
        let data = try JSONEncoder().encode(c)
        XCTAssertEqual(try JSONDecoder().decode(AppConfig.self, from: data).zoomSpeed, 0.5)

        let low = try JSONDecoder().decode(AppConfig.self, from: Data(#"{"zoomSpeed": 0.01}"#.utf8))
        XCTAssertEqual(low.zoomSpeed, 0.2)
        let high = try JSONDecoder().decode(AppConfig.self, from: Data(#"{"zoomSpeed": 99}"#.utf8))
        XCTAssertEqual(high.zoomSpeed, 6.0)
        let missing = try JSONDecoder().decode(AppConfig.self, from: Data("{}".utf8))
        XCTAssertEqual(missing.zoomSpeed, 1.0, "old configs keep today's zoom feel")
    }
}

extension AppConfigTests {
    /// Before the per-axis split `reverseScroll` flipped both axes; old configs must keep that.
    func testHorizontalReverseInheritsLegacyFlag() throws {
        let legacy = try JSONDecoder().decode(AppConfig.self, from: Data(#"{"reverseScroll":true}"#.utf8))
        XCTAssertTrue(legacy.reverseScroll)
        XCTAssertTrue(legacy.reverseScrollHorizontal)

        let split = try JSONDecoder().decode(
            AppConfig.self, from: Data(#"{"reverseScroll":true,"reverseScrollHorizontal":false}"#.utf8))
        XCTAssertTrue(split.reverseScroll)
        XCTAssertFalse(split.reverseScrollHorizontal)
    }

    func testScrollSettingsMirrorsGlobalFields() {
        var c = AppConfig()
        var s = c.scrollSettings
        s.scrollMode = .smoothStep
        s.scrollSpeed = 1.2
        s.reverseScrollHorizontal = true
        s.zoomSpeed = 0.4
        c.scrollSettings = s
        XCTAssertEqual(c.scrollMode, .smoothStep)
        XCTAssertEqual(c.scrollSpeed, 1.2, accuracy: 1e-9)
        XCTAssertTrue(c.reverseScrollHorizontal)
        XCTAssertEqual(c.zoomSpeed, 0.4, accuracy: 1e-9)
        XCTAssertEqual(c.scrollSettings, s)
    }

    func testDeviceProfilesRoundTrip() throws {
        var c = AppConfig()
        var s = ScrollDeviceSettings()
        s.scrollMode = .standard
        s.reverseScroll = true
        c.deviceProfiles = [DeviceProfile(id: "046d:b034", name: "MX Master 3S", settings: s)]
        let decoded = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(decoded.deviceProfiles, c.deviceProfiles)
        XCTAssertTrue(try JSONDecoder().decode(AppConfig.self, from: Data("{}".utf8)).deviceProfiles.isEmpty)
    }

    /// A broken profile is dropped alone, duplicates keep the first, and values are clamped.
    func testDeviceProfilesDecodeTolerantly() throws {
        let json = #"""
        {"deviceProfiles":[
          {"id":"1:1","name":"A","settings":{"scrollSpeed":99,"scrollMode":"bogus"}},
          {"name":"missing id"},
          {"id":"1:1","name":"dup","settings":{}}
        ]}
        """#
        let decoded = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.deviceProfiles.count, 1)
        XCTAssertEqual(decoded.deviceProfiles[0].name, "A")
        XCTAssertEqual(decoded.deviceProfiles[0].settings.scrollSpeed, 1.5, accuracy: 1e-9)
        XCTAssertEqual(decoded.deviceProfiles[0].settings.scrollMode, .smooth)
    }
}
