@testable import LANScreenShared
import XCTest

final class AppGroupSessionStoreTests: XCTestCase {
    func testSaveLoadAndClearPendingSession() {
        let suiteName = "group.com.lanscreen.test.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Impossible de créer UserDefaults isolé.")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = AppGroupSessionStore(userDefaults: defaults)
        let session = AcceptedBroadcastSession(
            sessionId: "sess-xyz",
            viewerIP: "192.168.1.44",
            viewerExtensionPort: 56001,
            sessionAuthTokenBase64: Data(repeating: 0xAA, count: 32).base64EncodedString(),
            viewerName: "iPhone A",
            broadcasterName: "iPhone B"
        )

        store.savePendingSession(session)
        let loaded = store.loadPendingSession()
        XCTAssertEqual(loaded, session)
        XCTAssertFalse(session.isExpired())

        store.clearPendingSession()
        XCTAssertNil(store.loadPendingSession())
    }

    func testExpiredSessionDetection() {
        let oldTimestamp = Date().timeIntervalSince1970 - (AppConstants.sessionExpirySeconds + 10)
        let session = AcceptedBroadcastSession(
            sessionId: "old",
            viewerIP: "192.168.1.10",
            viewerExtensionPort: 50000,
            sessionAuthTokenBase64: Data().base64EncodedString(),
            viewerName: "Viewer",
            broadcasterName: "Broadcaster",
            createdAt: oldTimestamp
        )
        XCTAssertTrue(session.isExpired())
    }
}
