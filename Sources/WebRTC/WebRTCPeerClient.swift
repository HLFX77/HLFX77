import CoreVideo
import Foundation
import LANScreenShared
import WebRTC

/// Hardware-accelerated H.264-only WebRTC peer client used by both the Viewer app and the Broadcaster extension.
final class WebRTCPeerClient: NSObject {
    enum Role {
        case broadcaster
        case viewer
    }

    private static let sslInitialized: Void = {
        RTCInitializeSSL()
    }()

    /// Hardware VideoToolbox H.264 factories avoid loading heavy software VP8/VP9 encoders inside the 50 MB extension.
    private static let sharedFactory: RTCPeerConnectionFactory = {
        _ = sslInitialized
        let encoderFactory = RTCVideoEncoderFactoryH264()
        let decoderFactory = RTCVideoDecoderFactoryH264()
        return RTCPeerConnectionFactory(encoderFactory: encoderFactory, decoderFactory: decoderFactory)
    }()

    private let role: Role
    private let stateQueue = DispatchQueue(label: "com.lanscreen.webrtc-client", qos: .userInteractive)
    private var peerConnection: RTCPeerConnection?
    private var videoSource: RTCVideoSource?
    private var videoCapturer: RTCVideoCapturer?
    private var localVideoTrack: RTCVideoTrack?
    private var pendingRemoteCandidates: [RTCIceCandidate] = []
    private var hasRemoteDescription = false
    private var deliveredTrackIDs: Set<String> = []
    private var lastAdaptedSize: (Int32, Int32) = (0, 0)

    var onIceCandidate: ((RTCIceCandidate) -> Void)?
    var onConnectionStateChanged: ((RTCPeerConnectionState) -> Void)?
    var onIceConnectionStateChanged: ((RTCIceConnectionState) -> Void)?
    var onRemoteVideoTrack: ((RTCVideoTrack) -> Void)?

    init(role: Role) {
        self.role = role
        super.init()
        configurePeerConnection()
    }

    deinit {
        close()
    }

    private func configurePeerConnection() {
        let config = RTCConfiguration()
        // Pure local Wi-Fi P2P LAN session: no external internet STUN/TURN servers required.
        config.iceServers = []
        config.sdpSemantics = .unifiedPlan
        config.iceTransportPolicy = .all
        config.continualGatheringPolicy = .gatherContinually
        config.bundlePolicy = .maxBundle
        config.rtcpMuxPolicy = .require

        let constraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: ["DtlsSrtpKeyAgreement": "true"]
        )

        let pc = Self.sharedFactory.peerConnection(with: config, constraints: constraints, delegate: self)
        self.peerConnection = pc

        if role == .broadcaster, let pc {
            let source = Self.sharedFactory.videoSource()
            let capturer = RTCVideoCapturer(delegate: source)
            let track = Self.sharedFactory.videoTrack(with: source, trackId: "lan_screen_video")
            track.isEnabled = true

            self.videoSource = source
            self.videoCapturer = capturer
            self.localVideoTrack = track

            if let sender = pc.add(track, streamIds: ["lan_screen_stream"]) {
                let params = sender.parameters
                for encoding in params.encodings {
                    encoding.maxBitrateBps = NSNumber(value: AppConstants.maxVideoBitrateBps)
                    encoding.maxFramerate = NSNumber(value: AppConstants.targetFPS)
                }
                sender.parameters = params
            }
        }
    }

    /// Creates and sets a local SDP Offer (initiated by the Broadcaster extension).
    func createOfferSDP() async throws -> String {
        guard let pc = peerConnection else {
            throw WebRTCAsyncError.emptySessionDescription
        }
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [
                "OfferToReceiveAudio": "false",
                "OfferToReceiveVideo": role == .viewer ? "true" : "false"
            ],
            optionalConstraints: nil
        )
        let offer = try await pc.makeOffer(constraints: constraints)
        try await pc.setLocalDescriptionAsync(offer)
        return offer.sdp
    }

    /// Applies the remote SDP Offer and produces a local SDP Answer (Viewer side).
    func acceptOfferAndCreateAnswer(remoteSDP: String) async throws -> String {
        guard let pc = peerConnection else {
            throw WebRTCAsyncError.emptySessionDescription
        }
        let offer = RTCSessionDescription(type: .offer, sdp: remoteSDP)
        try await pc.setRemoteDescriptionAsync(offer)
        markRemoteDescriptionAppliedAndDrainCandidates()

        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [
                "OfferToReceiveAudio": "false",
                "OfferToReceiveVideo": "true"
            ],
            optionalConstraints: nil
        )
        let answer = try await pc.makeAnswer(constraints: constraints)
        try await pc.setLocalDescriptionAsync(answer)
        return answer.sdp
    }

    /// Applies the Viewer's SDP Answer on the Broadcaster extension.
    func applyAnswerSDP(_ remoteSDP: String) async throws {
        guard let pc = peerConnection else {
            throw WebRTCAsyncError.emptySessionDescription
        }
        let answer = RTCSessionDescription(type: .answer, sdp: remoteSDP)
        try await pc.setRemoteDescriptionAsync(answer)
        markRemoteDescriptionAppliedAndDrainCandidates()
    }

    /// Queues or immediately applies an incoming ICE candidate received over TLS signaling.
    func addRemoteIceCandidate(sdp: String, sdpMLineIndex: Int32, sdpMid: String?) {
        let candidate = RTCIceCandidate(sdp: sdp, sdpMLineIndex: sdpMLineIndex, sdpMid: sdpMid)
        stateQueue.async { [weak self] in
            guard let self else { return }
            if self.hasRemoteDescription, let pc = self.peerConnection {
                Task {
                    try? await pc.addIceCandidateAsync(candidate)
                }
            } else {
                self.pendingRemoteCandidates.append(candidate)
            }
        }
    }

    /// Pushes a captured & downscaled `CVPixelBuffer` from ReplayKit into the WebRTC video track.
    func sendScreenFrame(pixelBuffer: CVPixelBuffer, rotationDegrees: Int, timestampNs: Int64) {
        guard role == .broadcaster, let videoSource, let videoCapturer else { return }

        let width = Int32(CVPixelBufferGetWidth(pixelBuffer))
        let height = Int32(CVPixelBufferGetHeight(pixelBuffer))
        if lastAdaptedSize.0 != width || lastAdaptedSize.1 != height {
            lastAdaptedSize = (width, height)
            videoSource.adaptOutputFormat(
                toWidth: width,
                height: height,
                fps: Int32(AppConstants.targetFPS)
            )
        }

        let rtcRotation: RTCVideoRotation
        switch rotationDegrees {
        case 90:
            rtcRotation = ._90
        case 180:
            rtcRotation = ._180
        case 270:
            rtcRotation = ._270
        default:
            rtcRotation = ._0
        }

        let rtcBuffer = RTCCVPixelBuffer(pixelBuffer: pixelBuffer)
        let frame = RTCVideoFrame(buffer: rtcBuffer, rotation: rtcRotation, timeStampNs: timestampNs)
        videoSource.capturer(videoCapturer, didCapture: frame)
    }

    func close() {
        stateQueue.sync {
            pendingRemoteCandidates.removeAll()
            hasRemoteDescription = false
            deliveredTrackIDs.removeAll()
        }
        localVideoTrack?.isEnabled = false
        localVideoTrack = nil
        videoCapturer = nil
        videoSource = nil
        peerConnection?.close()
        peerConnection = nil
    }

    private func markRemoteDescriptionAppliedAndDrainCandidates() {
        stateQueue.async { [weak self] in
            guard let self else { return }
            self.hasRemoteDescription = true
            let candidates = self.pendingRemoteCandidates
            self.pendingRemoteCandidates.removeAll()
            guard let pc = self.peerConnection else { return }
            for candidate in candidates {
                Task {
                    try? await pc.addIceCandidateAsync(candidate)
                }
            }
        }
    }

    private func emitRemoteVideoTrackIfNeeded(_ track: RTCVideoTrack) {
        stateQueue.async { [weak self] in
            guard let self else { return }
            guard !self.deliveredTrackIDs.contains(track.trackId) else { return }
            self.deliveredTrackIDs.insert(track.trackId)
            self.onRemoteVideoTrack?(track)
        }
    }
}

extension WebRTCPeerClient: RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        if let videoTrack = stream.videoTracks.first {
            emitRemoteVideoTrackIfNeeded(videoTrack)
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}

    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        onIceConnectionStateChanged?(newState)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        onConnectionStateChanged?(newState)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        onIceCandidate?(candidate)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}

    func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didAdd rtpReceiver: RTCRtpReceiver,
        streams mediaStreams: [RTCMediaStream]
    ) {
        if let videoTrack = rtpReceiver.track as? RTCVideoTrack {
            emitRemoteVideoTrackIfNeeded(videoTrack)
        }
    }
}
