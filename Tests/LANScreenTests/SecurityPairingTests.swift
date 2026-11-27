@testable import LANScreenShared
import XCTest

final class SecurityPairingTests: XCTestCase {
    func testEphemeralKeyAgreementProducesIdenticalSASAndAuthToken() throws {
        let viewerPriv = SecurityPairing.generateEphemeralKeyPair()
        let broadcasterPriv = SecurityPairing.generateEphemeralKeyPair()
        let sessionId = UUID().uuidString

        let viewerDerived = try SecurityPairing.deriveSessionKeys(
            localPrivateKey: viewerPriv,
            remotePublicKeyBase64: broadcasterPriv.publicKey.rawRepresentation.base64EncodedString(),
            sessionId: sessionId
        )
        let broadcasterDerived = try SecurityPairing.deriveSessionKeys(
            localPrivateKey: broadcasterPriv,
            remotePublicKeyBase64: viewerPriv.publicKey.rawRepresentation.base64EncodedString(),
            sessionId: sessionId
        )

        XCTAssertEqual(viewerDerived, broadcasterDerived)
        XCTAssertEqual(viewerDerived.verificationCode.count, 7) // XXX-XXX
        XCTAssertEqual(viewerDerived.sessionAuthToken.count, 32)
    }

    func testExtensionHMACProofVerificationSucceedsAndRejectsTampering() throws {
        let viewerPriv = SecurityPairing.generateEphemeralKeyPair()
        let broadcasterPriv = SecurityPairing.generateEphemeralKeyPair()
        let sessionId = "session-abc-123"

        let keys = try SecurityPairing.deriveSessionKeys(
            localPrivateKey: broadcasterPriv,
            remotePublicKeyBase64: viewerPriv.publicKey.rawRepresentation.base64EncodedString(),
            sessionId: sessionId
        )

        let proof = SecurityPairing.computeExtensionAuthProof(
            sessionId: sessionId,
            sessionAuthToken: keys.sessionAuthToken
        )

        XCTAssertTrue(
            SecurityPairing.verifyExtensionAuthProof(
                proof,
                sessionId: sessionId,
                sessionAuthToken: keys.sessionAuthToken
            )
        )
        XCTAssertFalse(
            SecurityPairing.verifyExtensionAuthProof(
                proof,
                sessionId: "wrong-session",
                sessionAuthToken: keys.sessionAuthToken
            )
        )
        XCTAssertFalse(
            SecurityPairing.verifyExtensionAuthProof(
                "not-a-valid-mac",
                sessionId: sessionId,
                sessionAuthToken: keys.sessionAuthToken
            )
        )
    }
}
