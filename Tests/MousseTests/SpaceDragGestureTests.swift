import XCTest
@testable import Mousse

/// Pointer-freeze lifecycle only: the hooks are injected, so nothing here touches the real cursor.
/// Follow-finger is off in every case so no dock-swipe events are posted; drags stay far below
/// the Space-switch threshold so no Symbolic HotKey fires either.
final class SpaceDragGestureTests: XCTestCase {

    private func makeGesture(lockPointer: Bool = true) -> (SpaceDragGesture, () -> (Int, Int)) {
        let gesture = SpaceDragGesture()
        gesture.button = 4
        gesture.followFinger = false
        gesture.lockPointer = lockPointer
        var freezes = 0, unfreezes = 0
        gesture.freezePointer = { freezes += 1 }
        gesture.unfreezePointer = { unfreezes += 1 }
        return (gesture, { (freezes, unfreezes) })
    }

    func testClickInsideDeadzoneNeverFreezes() {
        let (g, counts) = makeGesture()
        XCTAssertTrue(g.handleButtonDown(4))
        _ = g.handleDrag(deltaX: 3, deltaY: 2)
        XCTAssertTrue(g.handleButtonUp(4).wasClick)
        XCTAssertEqual(counts().0, 0)
    }

    func testDragFreezesOnceAndReleaseUnfreezesOnce() {
        let (g, counts) = makeGesture()
        XCTAssertTrue(g.handleButtonDown(4))
        _ = g.handleDrag(deltaX: 8, deltaY: 0) // crosses the 6 px deadzone
        XCTAssertEqual(counts().0, 1, "freeze exactly once at drag start")
        _ = g.handleDrag(deltaX: 3, deltaY: 0)
        _ = g.handleDrag(deltaX: 2, deltaY: 0)
        XCTAssertEqual(counts().0, 1, "no re-freeze mid-drag")
        _ = g.handleButtonUp(4)
        XCTAssertEqual(counts().1, 1)
    }

    func testCancelReleasesPointer() {
        let (g, counts) = makeGesture()
        XCTAssertTrue(g.handleButtonDown(4))
        _ = g.handleDrag(deltaX: 8, deltaY: 0)
        XCTAssertEqual(counts().0, 1)
        g.cancel()
        XCTAssertEqual(counts().1, 1)
        XCTAssertFalse(g.isActive)
    }

    func testLockPointerOffNeverFreezes() {
        let (g, counts) = makeGesture(lockPointer: false)
        XCTAssertTrue(g.handleButtonDown(4))
        _ = g.handleDrag(deltaX: 12, deltaY: 0)
        _ = g.handleButtonUp(4)
        XCTAssertEqual(counts().0, 0)
    }

    func testLockPointerRoundTripsInConfig() throws {
        var c = AppConfig()
        c.spaceDragLockPointer = true
        let data = try JSONEncoder().encode(c)
        XCTAssertTrue(try JSONDecoder().decode(AppConfig.self, from: data).spaceDragLockPointer)
        XCTAssertFalse(try JSONDecoder().decode(AppConfig.self, from: Data("{}".utf8)).spaceDragLockPointer,
                       "opt-in: old configs keep the pointer free")
    }
}
