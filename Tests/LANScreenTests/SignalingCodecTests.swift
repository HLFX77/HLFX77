@testable import LANScreenShared
import XCTest

final class SignalingCodecTests: XCTestCase {
    func testRoundTripSingleAndMultipleMessagesAcrossChunkedReads() throws {
        let m1 = SignalingMessage.connectionRequest(
            sessionId: "sess-1",
            viewerName: "iPhone de Paul",
            viewerIP: "192.168.1.14",
            viewerPublicKey: "BASE64KEY",
            viewerExtensionPort: 55100,
            protocolVersion: AppConstants.protocolVersion
        )
        let m2 = SignalingMessage.connectionAccepted(sessionId: "sess-1")
        let m3 = SignalingMessage.iceCandidate(
            sessionId: "sess-1",
            sdp: "candidate:1 1 UDP 2122252543 192.168.1.14 55000 typ host",
            sdpMLineIndex: 0,
            sdpMid: "0"
        )

        var combined = Data()
        combined.append(try LengthPrefixedFrameCodec.encode(m1))
        combined.append(try LengthPrefixedFrameCodec.encode(m2))
        combined.append(try LengthPrefixedFrameCodec.encode(m3))

        let decoder = LengthPrefixedFrameCodec.FrameDecoder()
        var decoded: [SignalingMessage] = []

        // Feed byte-slices of arbitrary sizes (3 bytes, 7 bytes, remainder) to simulate TCP fragmentation.
        var offset = 0
        let chunkSizes = [3, 7, 19, 64, combined.count]
        for size in chunkSizes where offset < combined.count {
            let end = min(combined.count, offset + size)
            let chunk = combined.subdata(in: offset..<end)
            decoded.append(contentsOf: try decoder.append(chunk))
            offset = end
        }

        XCTAssertEqual(decoded, [m1, m2, m3])
    }

    func testRejectsZeroOrOversizedFrameLength() {
        let decoder = LengthPrefixedFrameCodec.FrameDecoder()

        var zeroLengthHeader = Data([0x00, 0x00, 0x00, 0x00])
        XCTAssertThrowsError(try decoder.append(zeroLengthHeader)) { error in
            XCTAssertEqual(error as? LengthPrefixedFrameCodec.CodecError, .invalidFrameLength(0))
        }

        decoder.reset()
        let oversized = UInt32(AppConstants.maxSignalingFrameBytes + 1).bigEndian
        zeroLengthHeader = withUnsafeBytes(of: oversized) { Data($0) }
        XCTAssertThrowsError(try decoder.append(zeroLengthHeader))
    }
}
