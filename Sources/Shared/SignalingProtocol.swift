import Foundation

/// Wire-protocol messages exchanged over the encrypted local TLS signaling channel.
public enum SignalingMessage: Codable, Equatable {
    case connectionRequest(
        sessionId: String,
        viewerName: String,
        viewerIP: String,
        viewerPublicKey: String,
        viewerExtensionPort: UInt16,
        protocolVersion: Int
    )
    case pairingChallenge(
        sessionId: String,
        broadcasterName: String,
        broadcasterPublicKey: String
    )
    case connectionAccepted(sessionId: String)
    case connectionRejected(sessionId: String, reason: String)
    case connectionCancelled(sessionId: String, reason: String)
    case extensionHello(sessionId: String, hmacProof: String)
    case extensionAuthenticated(sessionId: String)
    case sdpOffer(sessionId: String, sdp: String)
    case sdpAnswer(sessionId: String, sdp: String)
    case iceCandidate(sessionId: String, sdp: String, sdpMLineIndex: Int32, sdpMid: String?)
    case broadcastStarted(sessionId: String, width: Int, height: Int)
    case broadcastEnded(sessionId: String, reason: String)
    case disconnect(sessionId: String, reason: String)
    case heartbeat(sessionId: String, timestamp: TimeInterval)

    public var sessionId: String {
        switch self {
        case .connectionRequest(let id, _, _, _, _, _),
             .pairingChallenge(let id, _, _),
             .connectionAccepted(let id),
             .connectionRejected(let id, _),
             .connectionCancelled(let id, _),
             .extensionHello(let id, _),
             .extensionAuthenticated(let id),
             .sdpOffer(let id, _),
             .sdpAnswer(let id, _),
             .iceCandidate(let id, _, _, _),
             .broadcastStarted(let id, _, _),
             .broadcastEnded(let id, _),
             .disconnect(let id, _),
             .heartbeat(let id, _):
            return id
        }
    }
}

/// 4-byte big-endian length-prefixed JSON framing codec for stream sockets (`NWConnection`).
public enum LengthPrefixedFrameCodec {
    public enum CodecError: Error, Equatable, LocalizedError {
        case payloadTooLarge(Int)
        case invalidFrameLength(UInt32)

        public var errorDescription: String? {
            switch self {
            case .payloadTooLarge(let size):
                return "Trame de signalisation trop volumineuse (\(size) octets)."
            case .invalidFrameLength(let length):
                return "Longueur de trame invalide (\(length))."
            }
        }
    }

    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    public static func encode(_ message: SignalingMessage) throws -> Data {
        let payload = try encoder.encode(message)
        guard payload.count <= AppConstants.maxSignalingFrameBytes else {
            throw CodecError.payloadTooLarge(payload.count)
        }

        var frame = Data(capacity: 4 + payload.count)
        var bigEndianLength = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &bigEndianLength) { frame.append(contentsOf: $0) }
        frame.append(payload)
        return frame
    }

    /// Stateful incremental frame decoder safe against TCP coalescing and partial reads.
    public final class FrameDecoder {
        private var buffer = Data()

        public init() {}

        public func append(_ chunk: Data) throws -> [SignalingMessage] {
            if !chunk.isEmpty {
                buffer.append(chunk)
            }

            var messages: [SignalingMessage] = []
            while buffer.count >= 4 {
                let b0 = UInt32(buffer[buffer.startIndex]) << 24
                let b1 = UInt32(buffer[buffer.startIndex + 1]) << 16
                let b2 = UInt32(buffer[buffer.startIndex + 2]) << 8
                let b3 = UInt32(buffer[buffer.startIndex + 3])
                let payloadLength = b0 | b1 | b2 | b3

                guard payloadLength > 0, Int(payloadLength) <= AppConstants.maxSignalingFrameBytes else {
                    buffer.removeAll(keepingCapacity: false)
                    throw CodecError.invalidFrameLength(payloadLength)
                }

                let totalFrameBytes = 4 + Int(payloadLength)
                guard buffer.count >= totalFrameBytes else {
                    break
                }

                let payloadSlice = buffer.subdata(in: 4..<totalFrameBytes)
                buffer.removeSubrange(0..<totalFrameBytes)
                let message = try LengthPrefixedFrameCodec.decoder.decode(SignalingMessage.self, from: payloadSlice)
                messages.append(message)
            }
            return messages
        }

        public func reset() {
            buffer.removeAll(keepingCapacity: false)
        }
    }
}
