import Foundation

enum ConnectionStatus: Equatable {
    case disconnected
    case listening
    case connecting
    case awaitingAcceptance(code: String)
    case waitingForBroadcast(code: String)
    case connected
    case broadcasting
    case error(String)

    var badgeTitle: String {
        switch self {
        case .connected, .broadcasting:
            return "CONNECTÉ"
        case .connecting, .awaitingAcceptance, .waitingForBroadcast:
            return "EN COURS"
        case .listening, .disconnected, .error:
            return "DÉCONNECTÉ"
        }
    }

    var isConnected: Bool {
        switch self {
        case .connected, .broadcasting:
            return true
        default:
            return false
        }
    }

    var detailDescription: String {
        switch self {
        case .disconnected:
            return "Déconnecté — Aucun Wi-Fi détecté ou session fermée"
        case .listening:
            return "Prêt sur le réseau Wi-Fi local"
        case .connecting:
            return "Connexion sécurisée TLS en cours..."
        case .awaitingAcceptance(let code):
            return "En attente d'acceptation sur l'autre iPhone • Code \(code)"
        case .waitingForBroadcast(let code):
            return "Accepté (Code \(code)) — En attente du démarrage ReplayKit..."
        case .connected:
            return "Flux WebRTC en direct actif"
        case .broadcasting:
            return "Partage de cet écran en direct"
        case .error(let message):
            return message
        }
    }
}

struct IncomingConnectionRequest: Identifiable, Equatable {
    let id: String
    let sessionId: String
    let viewerName: String
    let viewerIP: String
    let viewerExtensionPort: UInt16
    let verificationCode: String
    let sessionAuthToken: Data
    let receivedAt: Date

    init(
        sessionId: String,
        viewerName: String,
        viewerIP: String,
        viewerExtensionPort: UInt16,
        verificationCode: String,
        sessionAuthToken: Data,
        receivedAt: Date = Date()
    ) {
        self.id = sessionId
        self.sessionId = sessionId
        self.viewerName = viewerName
        self.viewerIP = viewerIP
        self.viewerExtensionPort = viewerExtensionPort
        self.verificationCode = verificationCode
        self.sessionAuthToken = sessionAuthToken
        self.receivedAt = receivedAt
    }
}

struct BroadcasterSessionSummary: Equatable {
    let sessionId: String
    let viewerName: String
    let viewerIP: String
    let verificationCode: String
}
