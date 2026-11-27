import CryptoKit
import Foundation
import Network
import Security

/// Ephemeral Curve25519 key agreement + HKDF session key derivation + TLS 1.2 PSK options.
public enum SecurityPairing {
    public enum PairingError: Error, LocalizedError {
        case invalidPeerPublicKey
        case invalidSignatureData

        public var errorDescription: String? {
            switch self {
            case .invalidPeerPublicKey:
                return "Clé publique Curve25519 distante invalide."
            case .invalidSignatureData:
                return "Jeton d'authentification de session invalide."
            }
        }
    }

    public struct DerivedSessionKeys: Equatable {
        /// 6-digit Short Authentication String formatted as "XXX-XXX" shown on both iPhones.
        public let verificationCode: String
        /// 32-byte shared secret token used to authenticate the Broadcast Extension over LAN.
        public let sessionAuthToken: Data

        public init(verificationCode: String, sessionAuthToken: Data) {
            self.verificationCode = verificationCode
            self.sessionAuthToken = sessionAuthToken
        }
    }

    /// Generates an ephemeral Curve25519 private key for a single pairing session.
    public static func generateEphemeralKeyPair() -> Curve25519.KeyAgreement.PrivateKey {
        Curve25519.KeyAgreement.PrivateKey()
    }

    /// Derives both the human-verifiable 6-digit SAS code and the session HMAC token from ECDH.
    public static func deriveSessionKeys(
        localPrivateKey: Curve25519.KeyAgreement.PrivateKey,
        remotePublicKeyBase64: String,
        sessionId: String
    ) throws -> DerivedSessionKeys {
        guard
            let remoteKeyData = Data(base64Encoded: remotePublicKeyBase64),
            let remotePublicKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: remoteKeyData)
        else {
            throw PairingError.invalidPeerPublicKey
        }

        let sharedSecret = try localPrivateKey.sharedSecretFromKeyAgreement(with: remotePublicKey)
        let salt = Data(sessionId.utf8)

        let authSymmetricKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: Data("LANScreen-SessionAuth-v1".utf8),
            outputByteCount: 32
        )

        let sasSymmetricKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: Data("LANScreen-SAS-v1".utf8),
            outputByteCount: 8
        )

        let sasBytes = sasSymmetricKey.withUnsafeBytes { Data($0) }
        let numericValue = sasBytes.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } % 1_000_000
        let formatted = String(format: "%06u", numericValue)
        let sas = "\(formatted.prefix(3))-\(formatted.suffix(3))"

        let tokenData = authSymmetricKey.withUnsafeBytes { Data($0) }
        return DerivedSessionKeys(verificationCode: sas, sessionAuthToken: tokenData)
    }

    /// Computes an HMAC-SHA256 proof proving possession of `sessionAuthToken` for `sessionId`.
    public static func computeExtensionAuthProof(sessionId: String, sessionAuthToken: Data) -> String {
        let key = SymmetricKey(data: sessionAuthToken)
        let message = Data("extension-hello:\(sessionId)".utf8)
        let mac = HMAC<SHA256>.authenticationCode(for: message, using: key)
        return Data(mac).base64EncodedString()
    }

    /// Constant-time verification of the Broadcast Extension's HMAC-SHA256 proof.
    public static func verifyExtensionAuthProof(
        _ proofBase64: String,
        sessionId: String,
        sessionAuthToken: Data
    ) -> Bool {
        guard let proofData = Data(base64Encoded: proofBase64) else {
            return false
        }
        let key = SymmetricKey(data: sessionAuthToken)
        let message = Data("extension-hello:\(sessionId)".utf8)
        return HMAC<SHA256>.isValidAuthenticationCode(proofData, authenticating: message, using: key)
    }
}

/// Provides TLS 1.2 PSK (`TLS_PSK_WITH_AES_128_GCM_SHA256`) transport encryption over Network.framework.
public enum TLSPskConfiguration {
    /// PSK suite identifier `0x00A8` (`TLS_PSK_WITH_AES_128_GCM_SHA256`).
    private static let pskCipherSuiteRawValue: UInt16 = 0x00A8
    private static let defaultPSKIdentity = Data("lanscreen.local.v1".utf8)
    /// Application-layer transport PSK combined with per-session Curve25519 ECDH + DTLS-SRTP.
    private static let defaultPSKSecret = Data([
        0x4C, 0x41, 0x4E, 0x53, 0x63, 0x72, 0x65, 0x65,
        0x6E, 0x2D, 0x57, 0x69, 0x46, 0x69, 0x2D, 0x54,
        0x4C, 0x53, 0x2D, 0x50, 0x53, 0x4B, 0x2D, 0x32,
        0x30, 0x32, 0x36, 0x2D, 0x4B, 0x65, 0x79, 0x21
    ])

    private static let pskQueue = DispatchQueue(label: "com.lanscreen.tls-psk", qos: .userInitiated)

    public static func makeServerParameters(pskSecret: Data? = nil, identity: Data? = nil) -> NWParameters {
        let tlsOptions = makeTLSOptions(isClient: false, pskSecret: pskSecret ?? defaultPSKSecret, identity: identity ?? defaultPSKIdentity)
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 3
        tcpOptions.keepaliveInterval = 2
        tcpOptions.keepaliveCount = 2
        tcpOptions.noDelay = true

        let params = NWParameters(tls: tlsOptions, tcp: tcpOptions)
        params.requiredInterfaceType = .wifi
        params.allowLocalEndpointReuse = true
        params.includePeerToPeer = false
        return params
    }

    public static func makeClientParameters(pskSecret: Data? = nil, identity: Data? = nil) -> NWParameters {
        let tlsOptions = makeTLSOptions(isClient: true, pskSecret: pskSecret ?? defaultPSKSecret, identity: identity ?? defaultPSKIdentity)
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 3
        tcpOptions.keepaliveInterval = 2
        tcpOptions.keepaliveCount = 2
        tcpOptions.noDelay = true

        let params = NWParameters(tls: tlsOptions, tcp: tcpOptions)
        params.requiredInterfaceType = .wifi
        params.includePeerToPeer = false
        return params
    }

    private static func makeTLSOptions(isClient: Bool, pskSecret: Data, identity: Data) -> NWProtocolTLS.Options {
        let tlsOptions = NWProtocolTLS.Options()
        let secOptions = tlsOptions.securityProtocolOptions

        let pskDispatch = DispatchData(from: pskSecret)
        let identityDispatch = DispatchData(from: identity)

        sec_protocol_options_set_min_tls_protocol_version(secOptions, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(secOptions, .TLSv12)

        sec_protocol_options_add_pre_shared_key(
            secOptions,
            pskDispatch as __DispatchData,
            identityDispatch as __DispatchData
        )

        if isClient {
            sec_protocol_options_set_pre_shared_key_selection_block(secOptions, { _, _, completion in
                completion(identityDispatch as __DispatchData)
            }, pskQueue)
        }

        if let suite = tls_ciphersuite_t(rawValue: pskCipherSuiteRawValue) {
            sec_protocol_options_append_tls_ciphersuite(secOptions, suite)
        }

        return tlsOptions
    }
}

private extension DispatchData {
    init(from data: Data) {
        self = data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress, rawBuffer.count > 0 else {
                return DispatchData.empty
            }
            let typedPointer = baseAddress.assumingMemoryBound(to: UInt8.self)
            let bufferPointer = UnsafeBufferPointer(start: typedPointer, count: rawBuffer.count)
            return DispatchData(bytes: bufferPointer)
        }
    }
}
