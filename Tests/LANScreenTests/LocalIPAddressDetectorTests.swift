@testable import LANScreenShared
import XCTest

final class LocalIPAddressDetectorTests: XCTestCase {
    func testValidIPv4Addresses() {
        XCTAssertTrue(LocalIPAddressDetector.isValidIPv4("192.168.1.37"))
        XCTAssertTrue(LocalIPAddressDetector.isValidIPv4("10.0.0.1"))
        XCTAssertTrue(LocalIPAddressDetector.isValidIPv4("172.16.254.10"))
    }

    func testInvalidIPv4Addresses() {
        XCTAssertFalse(LocalIPAddressDetector.isValidIPv4(""))
        XCTAssertFalse(LocalIPAddressDetector.isValidIPv4("192.168.1"))
        XCTAssertFalse(LocalIPAddressDetector.isValidIPv4("192.168.1.256"))
        XCTAssertFalse(LocalIPAddressDetector.isValidIPv4("abc.def.ghi.jkl"))
        XCTAssertFalse(LocalIPAddressDetector.isValidIPv4("192.168.1.1.1"))
    }

    func testNormalizationHandlesFrenchCommaAndWhitespace() {
        XCTAssertEqual(LocalIPAddressDetector.normalizeIPInput(" 192,168,1,37 \n"), "192.168.1.37")
        XCTAssertEqual(LocalIPAddressDetector.normalizeIPInput("10. 0. 0. 15"), "10.0.0.15")
    }

    func testNonRoutableCheck() {
        XCTAssertTrue(LocalIPAddressDetector.isNonRoutableLocalAddress("127.0.0.1"))
        XCTAssertTrue(LocalIPAddressDetector.isNonRoutableLocalAddress("0.0.0.0"))
        XCTAssertFalse(LocalIPAddressDetector.isNonRoutableLocalAddress("192.168.1.37"))
    }
}
