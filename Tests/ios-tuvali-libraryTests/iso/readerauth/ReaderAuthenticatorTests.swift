import SwiftCBOR
import XCTest
@testable import ios_tuvali_library

/// mdoc reader authentication: ISO 18013-5 clause 9.1.4 and the Annex B Table B.6 profile.
final class ReaderAuthenticatorTests: XCTestCase {
    private let transcript = SessionTestVectors.bytes("sessionTranscriptBytes")
    private let mdlItemsRequest = SessionTestVectors.bytes("session.mdlItemsRequestBytes")
    private var root: SecCertificate!
    private var otherRoot: SecCertificate!
    // the test reader certificates are valid from 2026-01-01 to 2029-01-01
    private var validationTime: Date!

    override func setUpWithError() throws {
        root = try certificate("readerAuth.rootCertificate")
        otherRoot = try certificate("readerAuth.otherRootCertificate")
        validationTime = try date(SessionTestVectors.string("readerAuth.validationTime"))
    }

    private func authenticator(anchors: [SecCertificate]? = nil, now: Date? = nil) -> ReaderAuthenticator {
        let time = now ?? validationTime!
        return ReaderAuthenticator(trustAnchors: anchors ?? [root], now: { time })
    }

    private func readerAuth(_ name: String) throws -> CBOR {
        try decodeCbor(SessionTestVectors.bytes("readerAuth.\(name)"))
    }

    private func check(_ readerAuth: CBOR?, with authenticator: ReaderAuthenticator? = nil, items: [UInt8]? = nil) -> ReaderTrust {
        (authenticator ?? self.authenticator()).check(
            readerAuth,
            sessionTranscriptBytes: transcript,
            itemsRequestBytes: items ?? mdlItemsRequest
        )
    }

    // MARK: the four trust states

    func testCheckReturnsNotSignedWhenTheRequestHasNoReaderAuth() {
        let trust = check(nil)

        XCTAssertEqual(trust, .notSigned)
    }

    func testCheckReturnsVerifiedWithTheReaderNameForASignatureChainingToATrustedRoot() throws {
        let trust = check(try readerAuth("valid"))

        guard case let .verified(readerName, _) = trust else { return XCTFail("Not verified: \(trust)") }
        XCTAssertEqual(readerName, "Tuvali Test Reader")
    }

    func testCheckReturnsVerifiedForATwoCertificateChainThroughAnIntermediateCa() throws {
        let trust = check(try readerAuth("twoCertChain"))

        guard case let .verified(_, chain) = trust else { return XCTFail("Not verified: \(trust)") }
        XCTAssertEqual(chain.count, 2)
    }

    func testCheckReturnsUnverifiedForAValidSignatureWhoseRootIsNotInTheTrustList() throws {
        let trust = check(try readerAuth("untrustedRoot"))

        guard case let .unverified(readerName, _, _) = trust else { return XCTFail("Not unverified: \(trust)") }
        XCTAssertEqual(readerName, "Untrusted Test Reader")
    }

    func testCheckReturnsUnverifiedForAValidSignatureWhenNoTrustListIsConfigured() throws {
        let trust = check(try readerAuth("valid"), with: authenticator(anchors: []))

        guard case let .unverified(_, _, reason) = trust else { return XCTFail("Not unverified: \(trust)") }
        XCTAssertEqual(reason, "No trusted reader roots are configured")
    }

    func testCheckReturnsVerifiedWhenTheTrustListHoldsTheOtherRootAsWell() throws {
        let trust = check(try readerAuth("valid"), with: authenticator(anchors: [otherRoot, root]))

        guard case .verified = trust else { return XCTFail("Not verified: \(trust)") }
    }

    func testCheckReturnsUnverifiedWhenTheTrustListHoldsOnlyAnotherRoot() throws {
        // the chain leads to the test root, which this trust list does not hold
        let trust = check(try readerAuth("valid"), with: authenticator(anchors: [otherRoot]))

        guard case .unverified = trust else { return XCTFail("Not unverified: \(trust)") }
    }

    // MARK: signatures that must not be accepted

    func testCheckReturnsInvalidWhenTheSignatureDoesNotVerify() throws {
        let tampered = try rebuild(try readerAuth("valid"), signature: { bytes in
            var changed = bytes
            changed[0] &+= 1
            return changed
        })

        let trust = check(tampered)

        XCTAssertEqual(trust, .invalid(reason: "Reader signature does not verify"))
    }

    func testCheckReturnsInvalidForASignatureMadeOverADifferentSessionTranscript() throws {
        // a valid signature by a trusted reader, but for another session: a replay
        let trust = check(try readerAuth("otherTranscript"))

        XCTAssertEqual(trust, .invalid(reason: "Reader signature does not verify"))
    }

    func testCheckReturnsInvalidWhenTheItemsRequestDiffersFromWhatWasSigned() throws {
        let otherItems = SessionTestVectors.bytes("session.secondDocItemsRequestBytes")

        let trust = check(try readerAuth("valid"), items: otherItems)

        XCTAssertEqual(trust, .invalid(reason: "Reader signature does not verify"))
    }

    // MARK: the reader certificate

    func testCheckReturnsInvalidWhenTheReaderCertificateHasExpired() throws {
        // valid from 2020-01-01 to 2021-01-01
        let trust = check(try readerAuth("expiredLeaf"))

        XCTAssertEqual(trust, .invalid(reason: "Reader certificate has expired"))
    }

    func testCheckReturnsInvalidWhenTheReaderCertificateIsNotYetValid() throws {
        let beforeValidity = try date("2025-06-01T00:00:00Z")

        let trust = check(try readerAuth("valid"), with: authenticator(now: beforeValidity))

        XCTAssertEqual(trust, .invalid(reason: "Reader certificate is not yet valid"))
    }

    func testCheckReturnsInvalidWhenTheCertificatesExtendedKeyUsageIsNotMdocReaderAuthentication() throws {
        // extended key usage is TLS server authentication instead of 1.0.18013.5.1.6
        let trust = check(try readerAuth("wrongEku"))

        XCTAssertEqual(trust, .invalid(reason: "Reader certificate is not for mdoc reader authentication"))
    }

    func testCheckReturnsInvalidWhenX5chainHoldsSomethingThatIsNotACertificate() throws {
        let notACertificate = try rebuild(try readerAuth("valid"), unprotectedHeader: [33: .byteString([1, 2, 3])])

        let trust = check(notACertificate)

        guard case let .invalid(reason) = trust else { return XCTFail("Not invalid: \(trust)") }
        XCTAssertTrue(reason.hasPrefix("readerAuth could not be read"), reason)
    }

    // MARK: the COSE_Sign1 structure

    func testCheckReturnsInvalidForAnAlgorithmItDoesNotSupport() throws {
        // COSE alg -8 is EdDSA
        let eddsa = try rebuild(try readerAuth("valid"), protectedHeader: encodeCbor([1: -8]))

        let trust = check(eddsa)

        XCTAssertEqual(trust, .invalid(reason: "Unsupported signature algorithm"))
    }

    func testCheckReturnsVerifiedForASignatureWithTheFullySpecifiedAlgorithmEsp256() throws {
        // COSE alg -9 is ESP256: ECDSA with SHA-256 on P-256 only (RFC 9864)
        let trust = check(try readerAuth("esp256"))

        guard case let .verified(readerName, _) = trust else { return XCTFail("Not verified: \(trust)") }
        XCTAssertEqual(readerName, "Tuvali Test Reader")
    }

    func testCheckReturnsInvalidWhenAFullySpecifiedAlgorithmNamesAnotherCurveThanTheReaderKey() throws {
        // COSE alg -51 is ESP384 (P-384 only); this signature is SHA-384 ECDSA made with a P-256 key
        let trust = check(try readerAuth("esp384WithP256Key"))

        XCTAssertEqual(trust, .invalid(reason: "Reader key is not on P-384, which the signature algorithm requires"))
    }

    func testCheckReturnsInvalidWhenTheUnprotectedHeaderHasNoX5chain() throws {
        let noChain = try rebuild(try readerAuth("valid"), unprotectedHeader: [:])

        let trust = check(noChain)

        XCTAssertEqual(trust, .invalid(reason: "readerAuth has no x5chain"))
    }

    func testCheckReturnsInvalidWhenThePayloadIsNotNull() throws {
        // clause 9.1.4: the payload is detached, so it must be null
        let attachedPayload = try rebuild(try readerAuth("valid"), payload: .byteString([1]))

        let trust = check(attachedPayload)

        XCTAssertEqual(trust, .invalid(reason: "readerAuth payload must be detached (null)"))
    }

    func testCheckReturnsInvalidWhenReaderAuthIsNotAFourElementArray() {
        let notCose: CBOR = [1, 2]

        let trust = check(notCose)

        XCTAssertEqual(trust, .invalid(reason: "readerAuth is not a COSE_Sign1"))
    }

    func testCheckAcceptsACoseSign1ThatCarriesTheCoseSign1Tag() throws {
        // clause 9.1.4 asks for an untagged COSE_Sign1; tag 18 is accepted as well
        let tagged = CBOR.tagged(CBOR.Tag(rawValue: 18), try readerAuth("valid"))

        let trust = check(tagged)

        guard case .verified = trust else { return XCTFail("Not verified: \(trust)") }
    }


    func testRejectsDuplicateHeaderBucketsEvenWithAValidSignature() throws {
        let valid = try readerAuth("valid")
        var headers = try valid.items[1].asMap("headers")
        headers[1] = -7
        XCTAssertEqual(check(try rebuild(valid, unprotectedHeader: .map(headers))),
                       .invalid(reason: "COSE header label appears in both buckets"))
    }

    func testRejectsUnprotectedCritEvenWithAValidSignature() throws {
        let valid = try readerAuth("valid")
        var headers = try valid.items[1].asMap("headers")
        headers[2] = [42]
        XCTAssertEqual(check(try rebuild(valid, unprotectedHeader: .map(headers))),
                       .invalid(reason: "crit must be protected"))
    }

    func testRejectsUnknownOrMissingCriticalProtectedHeaders() throws {
        let valid = try readerAuth("valid")
        for header: CBOR in [[1: -7, 2: [42], 42: true], [1: -7, 2: [42]]] {
            XCTAssertEqual(check(try rebuild(valid, protectedHeader: encodeCbor(header))),
                           .invalid(reason: "Unsupported critical COSE header"))
        }
    }

    func testRejectsExcessiveCertificateChains() throws {
        let valid = try readerAuth("valid")
        let headers = try valid.items[1].asMap("headers")
        let leaf = try XCTUnwrap(headers[33])
        XCTAssertEqual(check(try rebuild(valid, unprotectedHeader: [33: .array(Array(repeating: leaf, count: 9))])),
                       .invalid(reason: "x5chain exceeds certificate count or size limits"))
    }

    private func certificate(_ name: String) throws -> SecCertificate {
        try XCTUnwrap(SecCertificateCreateWithData(nil, Data(SessionTestVectors.bytes(name)) as CFData))
    }

    private func date(_ text: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: text))
    }

    /// Rebuilds a COSE_Sign1 with some parts replaced, to test one fault at a time.
    private func rebuild(
        _ original: CBOR,
        protectedHeader: [UInt8]? = nil,
        unprotectedHeader: CBOR? = nil,
        payload: CBOR? = nil,
        signature: (([UInt8]) -> [UInt8])? = nil
    ) throws -> CBOR {
        let parts = original.items
        let originalSignature = try XCTUnwrap(parts[3].bytes)
        return [
            protectedHeader.map(CBOR.byteString) ?? parts[0],
            unprotectedHeader ?? parts[1],
            payload ?? parts[2],
            .byteString(signature?(originalSignature) ?? originalSignature),
        ]
    }
}
