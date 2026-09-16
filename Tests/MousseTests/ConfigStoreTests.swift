import XCTest
@testable import Mousse

final class ConfigStoreTests: XCTestCase {

    @MainActor
    func testCorruptBackupSitsNextToConfigWithTimestamp() {
        let config = URL(fileURLWithPath: "/tmp/Mousse/config.json")
        let date = Date(timeIntervalSince1970: 0)
        let backup = ConfigStore.corruptBackupURL(for: config, at: date)
        XCTAssertEqual(backup.deletingLastPathComponent().path, "/tmp/Mousse")
        XCTAssertEqual(backup.lastPathComponent, "config-corrupt-1970-01-01T00-00-00Z.json")
        XCTAssertFalse(backup.lastPathComponent.contains(":"), "colons render as slashes in Finder")
    }

    @MainActor
    func testTwoBackupsAtDifferentTimesDoNotCollide() {
        let config = URL(fileURLWithPath: "/tmp/Mousse/config.json")
        let a = ConfigStore.corruptBackupURL(for: config, at: Date(timeIntervalSince1970: 0))
        let b = ConfigStore.corruptBackupURL(for: config, at: Date(timeIntervalSince1970: 1))
        XCTAssertNotEqual(a, b)
    }

    func testPersistenceIssueMessagesMentionBackupPathWhenKnown() {
        let withPath = ConfigPersistenceIssue.corruptConfigRecovered(backupPath: "/x/y.json")
        XCTAssertTrue(withPath.message.contains("/x/y.json"))
        let without = ConfigPersistenceIssue.corruptConfigRecovered(backupPath: nil)
        XCTAssertTrue(without.message.contains("could not be backed up"))
        XCTAssertTrue(ConfigPersistenceIssue.saveFailed("disk full").message.contains("disk full"))
    }
}
