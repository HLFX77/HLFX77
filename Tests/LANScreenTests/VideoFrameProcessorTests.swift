@testable import LANScreenShared
import XCTest

final class VideoFrameProcessorTests: XCTestCase {
    func testScaledDimensionsPreserveAspectRatioAndEvenBounds() {
        let portrait = VideoGeometry.scaledEvenDimensions(width: 1290, height: 2796, maxLongEdge: 1280)
        XCTAssertEqual(portrait.height, 1280)
        XCTAssertEqual(portrait.width % 2, 0)
        XCTAssertEqual(portrait.height % 2, 0)
        XCTAssertLessThanOrEqual(max(portrait.width, portrait.height), 1280)

        let landscape = VideoGeometry.scaledEvenDimensions(width: 2556, height: 1179, maxLongEdge: 1280)
        XCTAssertEqual(landscape.width, 1280)
        XCTAssertEqual(landscape.width % 2, 0)
        XCTAssertEqual(landscape.height % 2, 0)

        let smallOdd = VideoGeometry.scaledEvenDimensions(width: 721, height: 1081, maxLongEdge: 1280)
        XCTAssertEqual(smallOdd.width, 720)
        XCTAssertEqual(smallOdd.height, 1080)
    }

    func testOrientationRotationMapping() {
        XCTAssertEqual(VideoGeometry.rotationDegrees(forOrientationRawValue: nil), 0)
        XCTAssertEqual(VideoGeometry.rotationDegrees(forOrientationRawValue: 1), 0) // up
        XCTAssertEqual(VideoGeometry.rotationDegrees(forOrientationRawValue: 8), 90) // left
        XCTAssertEqual(VideoGeometry.rotationDegrees(forOrientationRawValue: 3), 180) // down
        XCTAssertEqual(VideoGeometry.rotationDegrees(forOrientationRawValue: 6), 270) // right
    }

    func testFrameRateLimiterThrottlesExcessFrames() {
        let limiter = FrameRateLimiter(targetFPS: 20) // 0.05s interval
        XCTAssertTrue(limiter.shouldProcessFrame(at: 10.00))
        XCTAssertFalse(limiter.shouldProcessFrame(at: 10.02))
        XCTAssertTrue(limiter.shouldProcessFrame(at: 10.055))
    }
}
