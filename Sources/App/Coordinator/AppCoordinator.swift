import Combine
import CryptoKit
import Foundation
import LANScreenShared
import SwiftUI
import UIKit
import WebRTC

@MainActor
final class AppCoordinator: ObservableObject {
    // MARK: - Published UI State
    @Published private(set) var localIPAddress: String?
    @Published private(set) var isWiFiConnected: Bool = false
    @Published var targetIPInput: String = ""
    @Published private(set) var recentIPs: [String] = []
    @Published private(set) var connectionStatus: ConnectionStatus = .disconnected
    @Published private(set) var isCopiedBannerVisible: Bool = false
    @Published private(set) var validationErrorMessage: String?

    // Broadcaster incoming & active states
    @Published var pendingIncomingRequest: IncomingConnectionRequest?
    @Published var activeBroadcasterSession: BroadcasterSessionSummary?
    @Published var isShowingBroadcasterSetup: Bool = false
    @Published private(set) var broadcastRuntimeStatus: BroadcastRuntimeStatus = BroadcastRuntimeStatus(sessionId: nil, phase: .idle)

    // Viewer active states
    @Published var isShowingViewer: Bool = false
    @Published private(set) var remoteDeviceName: String = "iPhone distant"
    @Published private(set) var remoteVideoTrack: RTCVideoTrack?
    @Published private(set) var remoteVideoSize: CGSize = .zero

    let permissionsManager = PermissionsManager()

    private let networkMonitor = WiFiNetworkMonitor()
    private let sessionStore = AppGroupSessionStore()
    private var cancellables = Set<AnyCancellable>()

    // Persistent LAN control listener (port 54321)
    private var controlServer: TLSSignalingServer?
    private var incomingControlConnection: TLSSignalingConnection?

    // Viewer session state
    private var viewerExtensionServer: TLSSignalingServer?
    private var viewerControlConnection: TLSSignalingConnection?
    private var viewerExtensionConnection: TLSSignalingConnection?
    private var viewerWebRTCClient: WebRTCPeerClient?
    private var viewerPrivateKey: Curve25519.KeyAgreement.PrivateKey?
    private var activeViewerSessionId: String?
    private var viewerAuthToken: Data?
    private var viewerVerificationCode: String = ""
    private var viewerHeartbeatTimer: Timer?
    private var lastExtensionHeartbeatAt: TimeInterval = 0

    // Broadcaster runtime sync timer
    private var broadcasterStatusTimer: Timer?

    private enum DefaultsKeys {
        static let recentIPs = "lanscreen.recentTargetIPs"
    }

    init() {
        self.recentIPs = UserDefaults.standard.stringArray(forKey: DefaultsKeys.recentIPs) ?? []
        if let firstRecent = recentIPs.first {
            self.targetIPInput = firstRecent
        }

        bindNetworkMonitor()
        bindNotifications()
        observeBroadcastExtensionUpdates()
    }

    func onAppLaunch() {
        networkMonitor.start()
        permissionsManager.refreshNotificationStatus()
        permissionsManager.requestNotificationPermissionIfNeeded()
        permissionsManager.triggerLocalNetworkPermissionCheck()
        startControlListenerIfNeeded()
        syncBroadcastRuntimeStatus()
    }

    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            networkMonitor.refreshNow()
            permissionsManager.refreshNotificationStatus()
            startControlListenerIfNeeded()
            syncBroadcastRuntimeStatus()
        default:
            break
        }
    }

    func refreshLocalIP() {
        networkMonitor.refreshNow()
        startControlListenerIfNeeded()
    }

    func copyLocalIP() {
        guard let ip = localIPAddress else { return }
        UIPasteboard.general.string = ip
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
        isCopiedBannerVisible = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.isCopiedBannerVisible = false
        }
    }

    func selectRecentIP(_ ip: String) {
        targetIPInput = ip
        validationErrorMessage = nil
    }

    // MARK: - Viewer Connection Flow

    func connectToRemoteIP() {
        validationErrorMessage = nil
        let normalizedIP = LocalIPAddressDetector.normalizeIPInput(targetIPInput)
        targetIPInput = normalizedIP

        guard isWiFiConnected, let localIP = localIPAddress else {
            validationErrorMessage = "Connectez cet iPhone au réseau Wi-Fi local avant de démarrer."
            return
        }

        guard LocalIPAddressDetector.isValidIPv4(normalizedIP),
              !LocalIPAddressDetector.isNonRoutableLocalAddress(normalizedIP) else {
            validationErrorMessage = "Adresse IP invalide. Exemple attendu : 192.168.1.37"
            return
        }

        guard normalizedIP != localIP else {
            validationErrorMessage = "Impossible de vous connecter à l'adresse IP de ce même iPhone."
            return
        }

        guard activeBroadcasterSession == nil, pendingIncomingRequest == nil else {
            validationErrorMessage = "Terminez ou refusez la session en cours avant d'initier une nouvelle connexion."
            return
        }

        disconnectViewerSession(notifyPeer: true, reason: "Nouvelle connexion démarrée", newStatus: .connecting)
        saveRecentIP(normalizedIP)

        let sessionId = UUID().uuidString
        let ephemeralKey = SecurityPairing.generateEphemeralKeyPair()

        self.activeViewerSessionId = sessionId
        self.viewerPrivateKey = ephemeralKey
        self.viewerAuthToken = nil
        self.viewerVerificationCode = ""
        self.remoteDeviceName = normalizedIP
        self.connectionStatus = .connecting

        let extServer = TLSSignalingServer(port: 0, advertiseBonjour: false)
        self.viewerExtensionServer = extServer

        extServer.onListenerFailure = { [weak self] _ in
            Task { @MainActor in
                self?.disconnectViewerSession(
                    notifyPeer: false,
                    reason: "",
                    newStatus: .error("Impossible d'ouvrir le port local sécurisé pour WebRTC.")
                )
            }
        }

        extServer.onNewConnection = { [weak self] inboundConnection in
            Task { @MainActor in
                self?.handleIncomingExtensionConnection(inboundConnection, expectedSessionId: sessionId)
            }
        }

        extServer.onListening = { [weak self] boundPort in
            Task { @MainActor in
                self?.openControlConnectionToBroadcaster(
                    targetIP: normalizedIP,
                    localIP: localIP,
                    sessionId: sessionId,
                    publicKeyBase64: ephemeralKey.publicKey.rawRepresentation.base64EncodedString(),
                    extensionPort: boundPort
                )
            }
        }

        do {
            try extServer.start()
        } catch {
            disconnectViewerSession(
                notifyPeer: false,
                reason: "",
                newStatus: .error("Erreur de démarrage du serveur local : \(error.localizedDescription)")
            )
        }
    }

    func disconnectViewerSession(
        notifyPeer: Bool = true,
        reason: String = "Session fermée par l'utilisateur.",
        newStatus: ConnectionStatus? = nil
    ) {
        viewerHeartbeatTimer?.invalidate()
        viewerHeartbeatTimer = nil

        if notifyPeer, let sessionId = activeViewerSessionId {
            let disconnectMsg = SignalingMessage.disconnect(sessionId: sessionId, reason: reason)
            viewerExtensionConnection?.send(disconnectMsg)
            viewerControlConnection?.send(disconnectMsg)
        }

        viewerControlConnection?.close()
        viewerControlConnection = nil

        viewerExtensionConnection?.close()
        viewerExtensionConnection = nil

        viewerExtensionServer?.stop()
        viewerExtensionServer = nil

        viewerWebRTCClient?.close()
        viewerWebRTCClient = nil

        activeViewerSessionId = nil
        viewerPrivateKey = nil
        viewerAuthToken = nil
        viewerVerificationCode = ""
        remoteVideoTrack = nil
        remoteVideoSize = .zero
        isShowingViewer = false

        if let newStatus {
            connectionStatus = newStatus
        } else {
            connectionStatus = isWiFiConnected ? .listening : .disconnected
        }
    }

    func updateRemoteVideoSize(_ size: CGSize) {
        remoteVideoSize = size
    }

    // MARK: - Broadcaster Request Handling

    func acceptIncomingRequest() {
        guard let request = pendingIncomingRequest else { return }
        permissionsManager.clearConnectionNotification(sessionId: request.sessionId)
        pendingIncomingRequest = nil

        let acceptedSession = AcceptedBroadcastSession(
            sessionId: request.sessionId,
            viewerIP: request.viewerIP,
            viewerExtensionPort: request.viewerExtensionPort,
            sessionAuthTokenBase64: request.sessionAuthToken.base64EncodedString(),
            viewerName: request.viewerName,
            broadcasterName: UIDevice.current.name
        )
        sessionStore.savePendingSession(acceptedSession)
        sessionStore.saveRuntimeStatus(
            BroadcastRuntimeStatus(sessionId: request.sessionId, phase: .idle, message: "En attente du lancement ReplayKit")
        )

        incomingControlConnection?.send(.connectionAccepted(sessionId: request.sessionId))

        activeBroadcasterSession = BroadcasterSessionSummary(
            sessionId: request.sessionId,
            viewerName: request.viewerName,
            viewerIP: request.viewerIP,
            verificationCode: request.verificationCode
        )
        broadcastRuntimeStatus = BroadcastRuntimeStatus(
            sessionId: request.sessionId,
            phase: .idle,
            message: "Prêt à démarrer ReplayKit"
        )
        isShowingBroadcasterSetup = true
        connectionStatus = .waitingForBroadcast(code: request.verificationCode)
        startBroadcasterStatusPolling()
    }

    func declineIncomingRequest() {
        guard let request = pendingIncomingRequest else { return }
        permissionsManager.clearConnectionNotification(sessionId: request.sessionId)
        pendingIncomingRequest = nil

        incomingControlConnection?.send(
            .connectionRejected(sessionId: request.sessionId, reason: "Demande refusée par l'utilisateur.")
        )
        incomingControlConnection?.close()
        incomingControlConnection = nil
        connectionStatus = isWiFiConnected ? .listening : .disconnected
    }

    func cancelOrStopBroadcasterSession() {
        broadcasterStatusTimer?.invalidate()
        broadcasterStatusTimer = nil

        if broadcastRuntimeStatus.phase == .broadcasting || broadcastRuntimeStatus.phase == .connecting {
            DarwinNotifier.shared.post(name: AppConstants.darwinStopBroadcastCommandNotification)
        } else if let session = activeBroadcasterSession {
            incomingControlConnection?.send(
                .connectionCancelled(sessionId: session.sessionId, reason: "Partage annulé avant le démarrage.")
            )
        }

        incomingControlConnection?.close()
        incomingControlConnection = nil
        sessionStore.clearPendingSession()

        activeBroadcasterSession = nil
        isShowingBroadcasterSetup = false
        broadcastRuntimeStatus = BroadcastRuntimeStatus(sessionId: nil, phase: .idle)
        connectionStatus = isWiFiConnected ? .listening : .disconnected
    }

    // MARK: - Private Network & Signaling Plumbing

    private func bindNetworkMonitor() {
        networkMonitor.$currentIPv4
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newIP in
                guard let self else { return }
                self.localIPAddress = newIP
                if newIP == nil {
                    self.controlServer?.stop()
                    self.controlServer = nil
                    if self.isShowingViewer {
                        self.disconnectViewerSession(
                            notifyPeer: false,
                            reason: "",
                            newStatus: .error("Connexion Wi-Fi perdue.")
                        )
                    } else {
                        self.connectionStatus = .disconnected
                    }
                } else {
                    self.startControlListenerIfNeeded()
                    if self.connectionStatus == .disconnected {
                        self.connectionStatus = .listening
                    }
                }
            }
            .store(in: &cancellables)

        networkMonitor.$isWiFiConnected
            .receive(on: DispatchQueue.main)
            .sink { [weak self] connected in
                self?.isWiFiConnected = connected
            }
            .store(in: &cancellables)
    }

    private func bindNotifications() {
        permissionsManager.onNotificationAction = { [weak self] sessionId, accepted in
            guard let self, let pending = self.pendingIncomingRequest, pending.sessionId == sessionId else {
                return
            }
            if accepted {
                self.acceptIncomingRequest()
            } else {
                self.declineIncomingRequest()
            }
        }
    }

    private func observeBroadcastExtensionUpdates() {
        DarwinNotifier.shared.observe(name: AppConstants.darwinBroadcastStateNotification) { [weak self] in
            Task { @MainActor in
                self?.syncBroadcastRuntimeStatus()
            }
        }
    }

    private func startBroadcasterStatusPolling() {
        broadcasterStatusTimer?.invalidate()
        broadcasterStatusTimer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.syncBroadcastRuntimeStatus()
            }
        }
    }

    private func syncBroadcastRuntimeStatus() {
        guard let latest = sessionStore.loadRuntimeStatus() else { return }
        broadcastRuntimeStatus = latest

        guard let active = activeBroadcasterSession, latest.sessionId == active.sessionId || latest.sessionId == nil else {
            return
        }

        switch latest.phase {
        case .idle:
            break
        case .connecting:
            connectionStatus = .connecting
        case .broadcasting:
            connectionStatus = .broadcasting
        case .stopped, .error:
            broadcasterStatusTimer?.invalidate()
            broadcasterStatusTimer = nil
            incomingControlConnection?.close()
            incomingControlConnection = nil
            activeBroadcasterSession = nil
            isShowingBroadcasterSetup = false
            if latest.phase == .error, let message = latest.message {
                connectionStatus = .error(message)
            } else {
                connectionStatus = isWiFiConnected ? .listening : .disconnected
            }
        }
    }

    private func startControlListenerIfNeeded() {
        guard controlServer == nil, localIPAddress != nil else { return }

        let server = TLSSignalingServer(port: AppConstants.signalingPort, advertiseBonjour: true)
        server.onListening = { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.connectionStatus == .disconnected {
                    self.connectionStatus = .listening
                }
            }
        }
        server.onListenerFailure = { [weak self] _ in
            Task { @MainActor in
                self?.controlServer = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self?.startControlListenerIfNeeded()
                }
            }
        }
        server.onNewConnection = { [weak self] connection in
            Task { @MainActor in
                self?.handleIncomingControlConnection(connection)
            }
        }

        do {
            try server.start()
            self.controlServer = server
        } catch {
            self.controlServer = nil
        }
    }

    private func handleIncomingControlConnection(_ connection: TLSSignalingConnection) {
        connection.onMessage = { [weak self, weak connection] message in
            Task { @MainActor in
                guard let self, let connection else { return }
                self.processIncomingControlMessage(message, on: connection)
            }
        }
        connection.onDisconnect = { [weak self, weak connection] _ in
            Task { @MainActor in
                guard let self, let connection else { return }
                if self.incomingControlConnection?.id == connection.id {
                    self.incomingControlConnection = nil
                    if let pending = self.pendingIncomingRequest {
                        self.permissionsManager.clearConnectionNotification(sessionId: pending.sessionId)
                        self.pendingIncomingRequest = nil
                    }
                    // If the broadcast hasn't started yet and viewer cancelled/closed, abort setup cleanly.
                    if self.activeBroadcasterSession != nil && self.broadcastRuntimeStatus.phase == .idle {
                        self.cancelOrStopBroadcasterSession()
                        self.connectionStatus = .error("Le spectateur a annulé la demande.")
                    }
                }
            }
        }
        connection.start()
    }

    private func processIncomingControlMessage(_ message: SignalingMessage, on connection: TLSSignalingConnection) {
        switch message {
        case .connectionRequest(let sessionId, let viewerName, let reportedIP, let viewerPubKey, let extPort, _):
            let resolvedIP = connection.remoteHostString ?? reportedIP

            if pendingIncomingRequest != nil || activeBroadcasterSession != nil || isShowingViewer {
                connection.send(.connectionRejected(sessionId: sessionId, reason: "Cet iPhone est déjà occupé dans une session."))
                connection.close()
                return
            }

            let privateKey = SecurityPairing.generateEphemeralKeyPair()
            do {
                let derived = try SecurityPairing.deriveSessionKeys(
                    localPrivateKey: privateKey,
                    remotePublicKeyBase64: viewerPubKey,
                    sessionId: sessionId
                )

                connection.send(
                    .pairingChallenge(
                        sessionId: sessionId,
                        broadcasterName: UIDevice.current.name,
                        broadcasterPublicKey: privateKey.publicKey.rawRepresentation.base64EncodedString()
                    )
                )

                self.incomingControlConnection = connection
                let request = IncomingConnectionRequest(
                    sessionId: sessionId,
                    viewerName: viewerName,
                    viewerIP: resolvedIP,
                    viewerExtensionPort: extPort,
                    verificationCode: derived.verificationCode,
                    sessionAuthToken: derived.sessionAuthToken
                )
                self.pendingIncomingRequest = request

                let haptic = UINotificationFeedbackGenerator()
                haptic.notificationOccurred(.warning)

                if UIApplication.shared.applicationState != .active {
                    permissionsManager.postIncomingConnectionNotification(request: request)
                }
            } catch {
                connection.send(.connectionRejected(sessionId: sessionId, reason: "Échec de l'échange de clés sécurisé."))
                connection.close()
            }

        case .disconnect(let sessionId, let reason):
            if pendingIncomingRequest?.sessionId == sessionId {
                permissionsManager.clearConnectionNotification(sessionId: sessionId)
                pendingIncomingRequest = nil
                incomingControlConnection?.close()
                incomingControlConnection = nil
                connectionStatus = isWiFiConnected ? .listening : .disconnected
            } else if activeBroadcasterSession?.sessionId == sessionId {
                cancelOrStopBroadcasterSession()
                connectionStatus = .error(reason)
            }

        default:
            break
        }
    }

    private func openControlConnectionToBroadcaster(
        targetIP: String,
        localIP: String,
        sessionId: String,
        publicKeyBase64: String,
        extensionPort: UInt16
    ) {
        let controlConn = TLSSignalingConnection(host: targetIP, port: AppConstants.signalingPort)
        self.viewerControlConnection = controlConn

        controlConn.onReady = { [weak controlConn] in
            controlConn?.send(
                .connectionRequest(
                    sessionId: sessionId,
                    viewerName: UIDevice.current.name,
                    viewerIP: localIP,
                    viewerPublicKey: publicKeyBase64,
                    viewerExtensionPort: extensionPort,
                    protocolVersion: AppConstants.protocolVersion
                )
            )
        }

        controlConn.onMessage = { [weak self] message in
            Task { @MainActor in
                self?.handleViewerControlMessage(message, expectedSessionId: sessionId)
            }
        }

        controlConn.onDisconnect = { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                // Once the Broadcast Upload Extension takes over via TLS, ignore control connection closes.
                guard self.activeViewerSessionId == sessionId, self.viewerExtensionConnection == nil else { return }
                let msg = error != nil
                    ? "Impossible de joindre \(targetIP) sur le Wi-Fi local. Vérifiez que LAN SCREEN est ouvert sur l'autre iPhone."
                    : "Connexion fermée avant le démarrage du partage."
                self.disconnectViewerSession(notifyPeer: false, reason: "", newStatus: .error(msg))
            }
        }

        controlConn.start()
    }

    private func handleViewerControlMessage(_ message: SignalingMessage, expectedSessionId: String) {
        guard message.sessionId == expectedSessionId, activeViewerSessionId == expectedSessionId else { return }

        switch message {
        case .pairingChallenge(_, let broadcasterName, let broadcasterPublicKey):
            guard let viewerPrivateKey else { return }
            do {
                let derived = try SecurityPairing.deriveSessionKeys(
                    localPrivateKey: viewerPrivateKey,
                    remotePublicKeyBase64: broadcasterPublicKey,
                    sessionId: expectedSessionId
                )
                self.viewerAuthToken = derived.sessionAuthToken
                self.viewerVerificationCode = derived.verificationCode
                self.remoteDeviceName = broadcasterName
                self.connectionStatus = .awaitingAcceptance(code: derived.verificationCode)
            } catch {
                disconnectViewerSession(
                    notifyPeer: true,
                    reason: "Clé de sécurité invalide",
                    newStatus: .error("Échec de vérification cryptographique avec l'appareil distant.")
                )
            }

        case .connectionAccepted:
            self.connectionStatus = .waitingForBroadcast(code: viewerVerificationCode)

        case .connectionRejected(_, let reason), .connectionCancelled(_, let reason):
            disconnectViewerSession(notifyPeer: false, reason: "", newStatus: .error(reason))

        default:
            break
        }
    }

    private func handleIncomingExtensionConnection(_ connection: TLSSignalingConnection, expectedSessionId: String) {
        connection.onMessage = { [weak self, weak connection] message in
            Task { @MainActor in
                guard let self, let connection else { return }
                self.processExtensionMessage(message, on: connection, expectedSessionId: expectedSessionId)
            }
        }

        connection.onDisconnect = { [weak self, weak connection] _ in
            Task { @MainActor in
                guard let self, let connection else { return }
                if self.viewerExtensionConnection?.id == connection.id {
                    self.disconnectViewerSession(
                        notifyPeer: false,
                        reason: "",
                        newStatus: .error("Le partage d'écran a été interrompu.")
                    )
                }
            }
        }

        connection.start()
    }

    private func processExtensionMessage(
        _ message: SignalingMessage,
        on connection: TLSSignalingConnection,
        expectedSessionId: String
    ) {
        guard activeViewerSessionId == expectedSessionId, message.sessionId == expectedSessionId else {
            connection.close()
            return
        }

        switch message {
        case .extensionHello(_, let hmacProof):
            guard let token = viewerAuthToken,
                  SecurityPairing.verifyExtensionAuthProof(hmacProof, sessionId: expectedSessionId, sessionAuthToken: token),
                  viewerExtensionConnection == nil else {
                connection.close()
                return
            }

            self.viewerExtensionConnection = connection
            self.lastExtensionHeartbeatAt = Date().timeIntervalSince1970

            // Control socket is no longer needed once the Broadcast Extension channel is authenticated.
            self.viewerControlConnection?.close()
            self.viewerControlConnection = nil

            let peerClient = WebRTCPeerClient(role: .viewer)
            self.viewerWebRTCClient = peerClient

            peerClient.onIceCandidate = { [weak connection] candidate in
                connection?.send(
                    .iceCandidate(
                        sessionId: expectedSessionId,
                        sdp: candidate.sdp,
                        sdpMLineIndex: candidate.sdpMLineIndex,
                        sdpMid: candidate.sdpMid
                    )
                )
            }

            peerClient.onRemoteVideoTrack = { [weak self] videoTrack in
                Task { @MainActor in
                    guard let self else { return }
                    self.remoteVideoTrack = videoTrack
                    self.connectionStatus = .connected
                    self.isShowingViewer = true
                }
            }

            peerClient.onConnectionStateChanged = { [weak self] state in
                Task { @MainActor in
                    guard let self, self.activeViewerSessionId == expectedSessionId else { return }
                    switch state {
                    case .connected:
                        self.connectionStatus = .connected
                        self.isShowingViewer = true
                    case .failed, .closed:
                        self.disconnectViewerSession(
                            notifyPeer: false,
                            reason: "",
                            newStatus: .error("Connexion WebRTC interrompue.")
                        )
                    default:
                        break
                    }
                }
            }

            connection.send(.extensionAuthenticated(sessionId: expectedSessionId))
            startViewerHeartbeat(sessionId: expectedSessionId)

        case .sdpOffer(_, let sdp):
            guard viewerExtensionConnection?.id == connection.id, let peerClient = viewerWebRTCClient else { return }
            Task {
                do {
                    let answerSDP = try await peerClient.acceptOfferAndCreateAnswer(remoteSDP: sdp)
                    connection.send(.sdpAnswer(sessionId: expectedSessionId, sdp: answerSDP))
                } catch {
                    await MainActor.run {
                        self.disconnectViewerSession(
                            notifyPeer: true,
                            reason: "Erreur SDP",
                            newStatus: .error("Impossible de négocier le flux vidéo WebRTC.")
                        )
                    }
                }
            }

        case .iceCandidate(_, let sdp, let mLineIndex, let sdpMid):
            guard viewerExtensionConnection?.id == connection.id else { return }
            viewerWebRTCClient?.addRemoteIceCandidate(sdp: sdp, sdpMLineIndex: mLineIndex, sdpMid: sdpMid)

        case .broadcastStarted:
            guard viewerExtensionConnection?.id == connection.id else { return }
            connectionStatus = .connected
            isShowingViewer = true

        case .broadcastEnded(_, let reason), .disconnect(_, let reason):
            guard viewerExtensionConnection?.id == connection.id else { return }
            disconnectViewerSession(notifyPeer: false, reason: "", newStatus: .error(reason))

        case .heartbeat:
            guard viewerExtensionConnection?.id == connection.id else { return }
            lastExtensionHeartbeatAt = Date().timeIntervalSince1970

        default:
            break
        }
    }

    private func startViewerHeartbeat(sessionId: String) {
        viewerHeartbeatTimer?.invalidate()
        viewerHeartbeatTimer = Timer.scheduledTimer(
            withTimeInterval: AppConstants.heartbeatIntervalSeconds,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.activeViewerSessionId == sessionId else { return }
                let now = Date().timeIntervalSince1970
                if now - self.lastExtensionHeartbeatAt > AppConstants.heartbeatTimeoutSeconds {
                    self.disconnectViewerSession(
                        notifyPeer: false,
                        reason: "",
                        newStatus: .error("Signal perdu avec l'iPhone émetteur.")
                    )
                    return
                }
                self.viewerExtensionConnection?.send(.heartbeat(sessionId: sessionId, timestamp: now))
            }
        }
    }

    private func saveRecentIP(_ ip: String) {
        var updated = recentIPs.filter { $0 != ip }
        updated.insert(ip, at: 0)
        if updated.count > 4 {
            updated = Array(updated.prefix(4))
        }
        recentIPs = updated
        UserDefaults.standard.set(updated, forKey: DefaultsKeys.recentIPs)
    }
}
