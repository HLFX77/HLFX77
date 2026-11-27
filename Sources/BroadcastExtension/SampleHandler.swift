import CoreMedia
import Foundation
import LANScreenShared
import ReplayKit
import WebRTC

/// ReplayKit Broadcast Upload Extension entry point.
/// Runs in an independent system process (`replayd`) with a strict ~50 MB RAM ceiling.
final class SampleHandler: RPBroadcastSampleHandler {
    private let sessionStore = AppGroupSessionStore()
    private let processingQueue = DispatchQueue(label: "com.lanscreen.broadcast.capture", qos: .userInteractive)
    private let frameSemaphore = DispatchSemaphore(value: 1)
    private let stateLock = NSLock()

    private var activeSession: AcceptedBroadcastSession?
    private var resizer: PixelBufferResizer?
    private var frameLimiter: FrameRateLimiter?
    private var signalingConnection: TLSSignalingConnection?
    private var webrtcClient: WebRTCPeerClient?
    private var heartbeatTimer: DispatchSourceTimer?

    private var isAuthenticated = false
    private var isFinishing = false
    private var lastHeartbeatReceivedAt: TimeInterval = Date().timeIntervalSince1970

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        guard let session = sessionStore.loadPendingSession(),
              !session.isExpired(),
              let tokenData = session.sessionAuthTokenData else {
            let errorMessage = "Aucune connexion acceptée trouvée. Ouvrez LAN SCREEN et acceptez d'abord la demande de connexion."
            publishStatus(phase: .error, sessionId: nil, message: errorMessage)
            finishWithUserMessage(errorMessage, code: 1001)
            return
        }

        stateLock.lock()
        self.activeSession = session
        self.isAuthenticated = false
        self.isFinishing = false
        self.lastHeartbeatReceivedAt = Date().timeIntervalSince1970
        stateLock.unlock()

        self.resizer = PixelBufferResizer()
        self.frameLimiter = FrameRateLimiter(targetFPS: session.targetFPS)
        publishStatus(phase: .connecting, sessionId: session.sessionId, message: "Connexion sécurisée au spectateur...")

        DarwinNotifier.shared.observe(name: AppConstants.darwinStopBroadcastCommandNotification) { [weak self] in
            self?.stopBroadcastFromRemoteOrHost(reason: "Partage arrêté depuis LAN SCREEN.")
        }

        let peerClient = WebRTCPeerClient(role: .broadcaster)
        self.webrtcClient = peerClient

        let connection = TLSSignalingConnection(host: session.viewerIP, port: session.viewerExtensionPort)
        self.signalingConnection = connection

        peerClient.onIceCandidate = { [weak self] candidate in
            guard let self, let activeId = self.activeSession?.sessionId else { return }
            self.signalingConnection?.send(
                .iceCandidate(
                    sessionId: activeId,
                    sdp: candidate.sdp,
                    sdpMLineIndex: candidate.sdpMLineIndex,
                    sdpMid: candidate.sdpMid
                )
            )
        }

        peerClient.onConnectionStateChanged = { [weak self] state in
            guard let self, let activeId = self.activeSession?.sessionId else { return }
            switch state {
            case .connected:
                self.publishStatus(phase: .broadcasting, sessionId: activeId, message: "Diffusion WebRTC active")
                self.signalingConnection?.send(.broadcastStarted(sessionId: activeId, width: 0, height: 0))
            case .failed, .closed:
                self.stopBroadcastFromRemoteOrHost(reason: "La connexion WebRTC avec le spectateur a été interrompue.")
            default:
                break
            }
        }

        connection.onReady = { [weak self] in
            guard let self else { return }
            let proof = SecurityPairing.computeExtensionAuthProof(
                sessionId: session.sessionId,
                sessionAuthToken: tokenData
            )
            connection.send(.extensionHello(sessionId: session.sessionId, hmacProof: proof))
        }

        connection.onMessage = { [weak self] message in
            self?.handleSignalingMessage(message)
        }

        connection.onDisconnect = { [weak self] _ in
            self?.stopBroadcastFromRemoteOrHost(reason: "Le spectateur s'est déconnecté.")
        }

        connection.start()
    }

    override func broadcastPaused() {
        if let session = activeSession {
            publishStatus(phase: .connecting, sessionId: session.sessionId, message: "Diffusion en pause")
        }
    }

    override func broadcastResumed() {
        if let session = activeSession {
            publishStatus(phase: .broadcasting, sessionId: session.sessionId, message: "Diffusion WebRTC active")
        }
    }

    override func broadcastFinished() {
        teardown(notifyViewer: true, reason: "Partage d'écran arrêté sur l'émetteur.")
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        // Ignore audio buffers to avoid audio capture/encoding overhead under the strict 50 MB extension cap.
        guard sampleBufferType == .video else { return }
        guard CMSampleBufferIsValid(sampleBuffer), CMSampleBufferGetNumSamples(sampleBuffer) == 1 else { return }

        stateLock.lock()
        let ready = isAuthenticated && !isFinishing
        let session = activeSession
        stateLock.unlock()

        guard ready, let session, let frameLimiter else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let presentationSeconds = CMTIME_IS_VALID(pts) ? CMTimeGetSeconds(pts) : Date().timeIntervalSince1970
        guard frameLimiter.shouldProcessFrame(at: presentationSeconds) else { return }

        // Drop frame immediately if the previous frame is still encoding/scaling so memory never queues up.
        guard frameSemaphore.wait(timeout: .now()) == .success else { return }

        let orientationNumber = CMGetAttachment(
            sampleBuffer,
            key: RPVideoSampleOrientationKey as CFString,
            attachmentModeOut: nil
        ) as? NSNumber
        let rotationDegrees = VideoGeometry.rotationDegrees(forOrientationRawValue: orientationNumber?.uint32Value)
        let timestampNs = Int64(presentationSeconds * Double(NSEC_PER_SEC))

        processingQueue.async { [weak self] in
            defer { self?.frameSemaphore.signal() }
            guard let self else { return }

            autoreleasepool {
                self.stateLock.lock()
                let stillActive = self.isAuthenticated && !self.isFinishing
                let activeResizer = self.resizer
                let activeClient = self.webrtcClient
                self.stateLock.unlock()

                guard stillActive,
                      let activeResizer,
                      let activeClient,
                      let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                    return
                }

                let scaledBuffer = activeResizer.resizeIfNeeded(pixelBuffer, maxLongEdge: session.maxLongEdge)
                activeClient.sendScreenFrame(
                    pixelBuffer: scaledBuffer,
                    rotationDegrees: rotationDegrees,
                    timestampNs: timestampNs
                )
            }
        }
    }

    private func handleSignalingMessage(_ message: SignalingMessage) {
        guard let session = activeSession, message.sessionId == session.sessionId else { return }

        switch message {
        case .extensionAuthenticated:
            stateLock.lock()
            isAuthenticated = true
            lastHeartbeatReceivedAt = Date().timeIntervalSince1970
            stateLock.unlock()

            startHeartbeatTimer(sessionId: session.sessionId)

            Task { [weak self] in
                guard let self, let webrtcClient = self.webrtcClient else { return }
                do {
                    let offerSDP = try await webrtcClient.createOfferSDP()
                    self.signalingConnection?.send(.sdpOffer(sessionId: session.sessionId, sdp: offerSDP))
                } catch {
                    self.stopBroadcastFromRemoteOrHost(reason: "Échec de la négociation WebRTC.")
                }
            }

        case .sdpAnswer(_, let sdp):
            Task { [weak self] in
                guard let self, let webrtcClient = self.webrtcClient else { return }
                do {
                    try await webrtcClient.applyAnswerSDP(sdp)
                } catch {
                    self.stopBroadcastFromRemoteOrHost(reason: "Réponse SDP invalide reçue du spectateur.")
                }
            }

        case .iceCandidate(_, let sdp, let mLineIndex, let sdpMid):
            webrtcClient?.addRemoteIceCandidate(sdp: sdp, sdpMLineIndex: mLineIndex, sdpMid: sdpMid)

        case .heartbeat:
            stateLock.lock()
            lastHeartbeatReceivedAt = Date().timeIntervalSince1970
            stateLock.unlock()

        case .disconnect(_, let reason):
            stopBroadcastFromRemoteOrHost(reason: reason)

        default:
            break
        }
    }

    private func startHeartbeatTimer(sessionId: String) {
        heartbeatTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(
            deadline: .now() + AppConstants.heartbeatIntervalSeconds,
            repeating: AppConstants.heartbeatIntervalSeconds
        )
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let now = Date().timeIntervalSince1970
            self.stateLock.lock()
            let lastBeat = self.lastHeartbeatReceivedAt
            let finishing = self.isFinishing
            self.stateLock.unlock()

            guard !finishing else { return }
            if now - lastBeat > AppConstants.heartbeatTimeoutSeconds {
                self.stopBroadcastFromRemoteOrHost(reason: "Délai de connexion dépassé avec le spectateur.")
                return
            }
            self.signalingConnection?.send(.heartbeat(sessionId: sessionId, timestamp: now))
        }
        timer.resume()
        self.heartbeatTimer = timer
    }

    private func stopBroadcastFromRemoteOrHost(reason: String) {
        stateLock.lock()
        let alreadyFinishing = isFinishing
        isFinishing = true
        stateLock.unlock()
        guard !alreadyFinishing else { return }

        teardown(notifyViewer: true, reason: reason)
        finishWithUserMessage(reason, code: 1002)
    }

    private func teardown(notifyViewer: Bool, reason: String) {
        DarwinNotifier.shared.stopObserving(name: AppConstants.darwinStopBroadcastCommandNotification)
        heartbeatTimer?.cancel()
        heartbeatTimer = nil

        stateLock.lock()
        isAuthenticated = false
        isFinishing = true
        let session = activeSession
        let activeClient = webrtcClient
        activeSession = nil
        webrtcClient = nil
        resizer = nil
        frameLimiter = nil
        stateLock.unlock()

        if notifyViewer, let session {
            signalingConnection?.send(.broadcastEnded(sessionId: session.sessionId, reason: reason))
        }

        signalingConnection?.close()
        signalingConnection = nil

        // Drain any in-flight frame encoding task before tearing down WebRTC peer state.
        processingQueue.sync {}
        activeClient?.close()

        sessionStore.clearPendingSession()
        publishStatus(phase: .stopped, sessionId: session?.sessionId, message: reason)
    }

    private func publishStatus(phase: BroadcastRuntimeStatus.Phase, sessionId: String?, message: String?) {
        let status = BroadcastRuntimeStatus(
            sessionId: sessionId,
            phase: phase,
            message: message
        )
        sessionStore.saveRuntimeStatus(status)
        DarwinNotifier.shared.post(name: AppConstants.darwinBroadcastStateNotification)
    }

    private func finishWithUserMessage(_ message: String, code: Int) {
        let error = NSError(
            domain: AppConstants.broadcastExtensionBundleID,
            code: code,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
        finishBroadcastWithError(error)
    }
}
