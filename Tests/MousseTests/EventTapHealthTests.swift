import XCTest
@testable import Mousse

final class EventTapHealthTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func resolve(trusted: Bool = true, hasTap: Bool = true, enabled: Bool = true,
                         rebuildPending: Bool = false, creationFailed: Bool = false,
                         lastRecoveryAt: Date? = nil) -> EventTapHealth {
        EventTapHealth.resolve(accessibilityTrusted: trusted, hasTap: hasTap, tapEnabled: enabled,
                               rebuildPending: rebuildPending, creationFailed: creationFailed,
                               lastRecoveryAt: lastRecoveryAt, now: now)
    }

    func testHealthyWhenTapEnabledAndQuiet() {
        XCTAssertEqual(resolve(), .healthy)
    }

    func testPermissionMissingWinsOverEverything() {
        XCTAssertEqual(resolve(trusted: false, hasTap: false, creationFailed: true), .waitingForPermission)
    }

    func testCreationFailedIsFailed() {
        XCTAssertEqual(resolve(hasTap: false, creationFailed: true), .failed)
    }

    func testNoTapYetIsInitializing() {
        XCTAssertEqual(resolve(hasTap: false, enabled: false), .initializing)
    }

    func testRebuildPendingIsRecovering() {
        XCTAssertEqual(resolve(rebuildPending: true), .recovering)
    }

    func testDisabledTapIsRecovering() {
        XCTAssertEqual(resolve(enabled: false), .recovering)
    }

    func testRecentRecoveryStaysRecoveringForTwoSeconds() {
        XCTAssertEqual(resolve(lastRecoveryAt: now.addingTimeInterval(-1.9)), .recovering)
        XCTAssertEqual(resolve(lastRecoveryAt: now.addingTimeInterval(-2.0)), .healthy)
    }
}
