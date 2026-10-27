import CryptoKit
import SwiftCBOR
import XCTest
@testable import ios_tuvali_library

/// One mdoc session over a transport: ISO 18013-5 clause 9.1.1.4 steps 2 to 4.
final class MdocSessionTests: XCTestCase {
    private var deviceKey: EphemeralDeviceKey!
    private var engagement: DeviceEngagement!

    override func setUpWithError() throws {
        deviceKey = try EphemeralDeviceKey.fromPrivateScalar(SessionTestVectors.bytes("deviceKey.privateScalar"))
        let uuid = try XCTUnwrap(UUID(uuidString: SessionTestVectors.string("bleClientUuid")))
        engagement = DeviceEngagement.create(deviceKey: deviceKey, retrievalMethods: [.bleCentralClient(uuid: uuid)])
    }

    private func message(_ name: String) -> ReaderEvent {
        .message(SessionTestVectors.bytes("session.\(name)"))
    }

    private func sessionWith(_ incoming: ReaderEvent...) -> (MdocSession, ScriptedTransport) {
        let transport = ScriptedTransport()
        incoming.forEach(transport.queue)
        return (MdocSession(transport: transport, engagement: engagement), transport)
    }

    private func requestOf(_ event: SessionEvent) throws -> DeviceRequest {
        guard case let .request(request) = event else {
            return try XCTUnwrap(nil as DeviceRequest?, "Expected a request, got \(event)")
        }
        return request
    }

    private func error(of action: () async throws -> Void) async -> Error? {
        do {
            try await action()
            return nil
        } catch {
            return error
        }
    }

    // MARK: the normal exchange

    func testReceiveRequestSetsUpTheSessionAndReturnsTheReadersDecryptedRequest() async throws {
        let (session, _) = sessionWith(message("sessionEstablishment"))

        let event = try await session.receiveRequest()

        let request = try requestOf(event)
        XCTAssertEqual(request.docRequests.map(\.docType), ["org.iso.18013.5.1.mDL", "org.example.test.1"])
    }

    func testRespondSendsTheEncryptedResponseInASessionDataMessage() async throws {
        let (session, transport) = sessionWith(message("sessionEstablishment"))
        _ = try await session.receiveRequest()

        try await session.respond(SessionTestVectors.bytes("session.deviceResponse"))

        XCTAssertEqual(transport.sent.map(\.hex), [SessionTestVectors.string("session.responseSessionData")])
    }

    func testTerminateSendsStatus20() async throws {
        let (session, transport) = sessionWith(message("sessionEstablishment"))
        _ = try await session.receiveRequest()

        try await session.terminate()

        XCTAssertEqual(transport.sent.map(\.hex), [SessionTestVectors.string("session.statusTermination")])
    }

    func testReceiveRequestDecryptsAFurtherRequestWithTheNextCounter() async throws {
        let (session, _) = sessionWith(message("sessionEstablishment"), message("secondRequestSessionData"))
        _ = try await session.receiveRequest()

        let event = try await session.receiveRequest()

        XCTAssertEqual(try requestOf(event).docRequests.count, 1)
    }

    func testEverythingTheSessionSendsIsStrictlyEncodedCborWithSortedKeys() async throws {
        let (session, transport) = sessionWith(message("sessionEstablishment"))
        _ = try await session.receiveRequest()

        try await session.respond(SessionTestVectors.bytes("session.deviceResponse"))
        try await session.terminate()

        for sent in transport.sent {
            XCTAssertNoThrow(try requireStrictCbor(sent))
            // encodeCbor sorts map keys, so re-encoding what was decoded gives the same bytes
            XCTAssertEqual(encodeCbor(try decodeCbor(sent)), sent)
        }
    }

    func testSessionTranscriptBytesAreTheTranscriptOfThisSessionOnceTheReaderSentItsKey() async throws {
        let (session, _) = sessionWith(message("sessionEstablishment"))
        XCTAssertNil(session.sessionTranscriptBytes())

        _ = try await session.receiveRequest()

        XCTAssertEqual(session.sessionTranscriptBytes()?.hex, SessionTestVectors.string("sessionTranscriptBytes"))
    }

    // MARK: reader authentication

    func testReceiveRequestReportsVerifiedForADocumentSignedByATrustedReader() async throws {
        let root = try XCTUnwrap(SecCertificateCreateWithData(nil, Data(SessionTestVectors.bytes("readerAuth.rootCertificate")) as CFData))
        // the test reader certificates are valid from 2026-01-01 to 2029-01-01
        let validationTime = try XCTUnwrap(ISO8601DateFormatter().date(from: SessionTestVectors.string("readerAuth.validationTime")))
        let transport = ScriptedTransport(.message(SessionTestVectors.bytes("readerAuth.signedSessionEstablishment")))
        let authenticator = ReaderAuthenticator(trustAnchors: [root], now: { validationTime })
        let session = MdocSession(transport: transport, engagement: engagement, readerAuthenticator: authenticator)

        let event = try await session.receiveRequest()

        let trust = try requestOf(event).docRequests.first?.readerTrust
        guard case let .verified(readerName, _)? = trust else { return XCTFail("Not verified: \(String(describing: trust))") }
        XCTAssertEqual(readerName, "Tuvali Test Reader")
    }

    func testReceiveRequestReportsNotSignedForDocumentsTheReaderDidNotSign() async throws {
        let (session, _) = sessionWith(message("sessionEstablishment"))

        let event = try await session.receiveRequest()

        XCTAssertEqual(try requestOf(event).docRequests.map(\.readerTrust), [.notSigned, .notSigned])
    }

    // MARK: the reader ending

    func testReceiveRequestReturnsEndedWhenTheReaderSignalsEndOnTheTransport() async throws {
        let (session, _) = sessionWith(.ended)

        let event = try await session.receiveRequest()

        XCTAssertEqual(event, .ended(status: nil))
    }

    func testReceiveRequestReturnsEndedWithTheStatusWhenTheReaderSendsStatus20() async throws {
        let (session, transport) = sessionWith(message("sessionEstablishment"), message("statusTermination"))
        _ = try await session.receiveRequest()

        let event = try await session.receiveRequest()

        XCTAssertEqual(event, .ended(status: 20))
        XCTAssertTrue(transport.sent.isEmpty)
    }

    // MARK: errors and the status the reader is told

    func testReceiveRequestSendsStatus10AndThrowsInvalidReaderKeyErrorForAnInvalidReaderKey() async {
        // a SessionEstablishment whose reader key is not a point on P-256
        let zeros = CBOR.byteString([UInt8](repeating: 0, count: 32))
        let badKey = encodeCbor([1: 2, -1: 1, -2: zeros, -3: zeros])
        let establishment = encodeCbor([
            "eReaderKey": tag24(encodedCbor: badKey),
            "data": .byteString([UInt8](repeating: 0, count: 20)),
        ])
        let (session, transport) = sessionWith(.message(establishment))

        let failure = await error { _ = try await session.receiveRequest() }

        XCTAssertTrue(failure is InvalidReaderKeyError, "\(String(describing: failure))")
        XCTAssertEqual(transport.sent.map(\.hex), [SessionTestVectors.string("session.statusEncryptionError")])
    }

    func testReceiveRequestSendsStatus11AndThrowsCborDecodingErrorForAnUnreadableFirstMessage() async {
        // not CBOR at all: a truncated map header
        let (session, transport) = sessionWith(.message("a2".hexToBytes()))

        let failure = await error { _ = try await session.receiveRequest() }

        XCTAssertTrue(failure is CborDecodingError, "\(String(describing: failure))")
        XCTAssertEqual(transport.sent.map(\.hex), [SessionTestVectors.string("session.statusCborError")])
    }

    func testReceiveRequestSendsStatus10AndThrowsSessionDecryptionErrorWhenTheRequestDoesNotDecrypt() async {
        var tampered = SessionTestVectors.bytes("session.sessionEstablishment")
        tampered[tampered.count - 1] &+= 1
        let (session, transport) = sessionWith(.message(tampered))

        let failure = await error { _ = try await session.receiveRequest() }

        XCTAssertTrue(failure is SessionDecryptionError, "\(String(describing: failure))")
        XCTAssertEqual(transport.sent.map(\.hex), [SessionTestVectors.string("session.statusEncryptionError")])
    }

    func testReceiveRequestSendsStatus11AndThrowsCborDecodingErrorWhenTheDecryptedRequestIsMalformed() async throws {
        // a request that decrypts correctly but has no docRequests
        let malformedRequest = encodeCbor(["version": "1.0"])
        let readerCoseKey = try untag24(decodeCbor(SessionTestVectors.bytes("readerKey.eReaderKeyBytes")))
        let establishment = encodeCbor([
            "eReaderKey": tag24(encodedCbor: readerCoseKey),
            "data": .byteString(try encryptAsReader(malformedRequest)),
        ])
        let (session, transport) = sessionWith(.message(establishment))

        let failure = await error { _ = try await session.receiveRequest() }

        XCTAssertTrue(failure is CborDecodingError, "\(String(describing: failure))")
        XCTAssertEqual(transport.sent.map(\.hex), [SessionTestVectors.string("session.statusCborError")])
    }

    func testReceiveRequestSendsStatus10AndThrowsSessionProtocolErrorForASecondSessionEstablishment() async throws {
        // the reader tries to establish the session again: it is never re-keyed
        let (session, transport) = sessionWith(message("sessionEstablishment"), message("sessionEstablishment"))
        _ = try await session.receiveRequest()

        let failure = await error { _ = try await session.receiveRequest() }

        XCTAssertTrue(failure is SessionProtocolError, "\(String(describing: failure))")
        XCTAssertEqual(transport.sent.map(\.hex), [SessionTestVectors.string("session.statusEncryptionError")])
    }

    func testReceiveRequestSendsStatus11AndThrowsSessionProtocolErrorWhenTheFirstMessageIsSessionData() async {
        // a request before any SessionEstablishment, so there are no session keys yet
        let (session, transport) = sessionWith(message("secondRequestSessionData"))

        let failure = await error { _ = try await session.receiveRequest() }

        XCTAssertTrue(failure is SessionProtocolError, "\(String(describing: failure))")
        XCTAssertEqual(transport.sent.map(\.hex), [SessionTestVectors.string("session.statusCborError")])
    }

    func testReceiveRequestSendsStatus11ForASessionDataWithNeitherDataNorStatus() async throws {
        let empty = encodeCbor(["x": 1])
        let (session, transport) = sessionWith(message("sessionEstablishment"), .message(empty))
        _ = try await session.receiveRequest()

        let failure = await error { _ = try await session.receiveRequest() }

        XCTAssertTrue(failure is SessionProtocolError, "\(String(describing: failure))")
        XCTAssertEqual(transport.sent.map(\.hex), [SessionTestVectors.string("session.statusCborError")])
    }

    func testReceiveRequestStillThrowsTheOriginalErrorWhenTellingTheReaderFails() async {
        let (session, transport) = sessionWith(.message("a2".hexToBytes()))
        transport.failOnSend = GattDisconnectedError(reason: .remoteDisconnected)

        let failure = await error { _ = try await session.receiveRequest() }

        XCTAssertTrue(failure is CborDecodingError, "\(String(describing: failure))")
    }

    func testReceiveRequestTellsTheReaderNothingWhenItsTaskIsCancelled() async {
        let (session, transport) = sessionWith()
        let receiving = Task { try await session.receiveRequest() }
        try? await Task.sleep(nanoseconds: 20_000_000)

        receiving.cancel()

        let failure = await errorThrown(by: receiving)
        XCTAssertTrue(failure is CancellationError, "\(String(describing: failure))")
        XCTAssertTrue(transport.sent.isEmpty)
    }

    // MARK: order and cleanup

    func testRespondThrowsSessionEncryptionStateErrorBeforeARequestWasReceived() async {
        let (session, _) = sessionWith()

        let failure = await error { try await session.respond([1]) }

        XCTAssertTrue(failure is SessionEncryptionStateError, "\(String(describing: failure))")
    }

    func testWipeDestroysTheSessionKeysAndTheDeviceKey() async throws {
        let (session, _) = sessionWith(message("sessionEstablishment"))
        _ = try await session.receiveRequest()

        session.wipe()

        XCTAssertThrowsError(try deviceKey.requirePrivateKey(), ofType: DeviceKeyWipedError.self)
        let failure = await error { try await session.respond([1]) }
        XCTAssertTrue(failure is SessionEncryptionStateError, "\(String(describing: failure))")
    }

    /// Encrypts [plaintext] as the reader's first message would be: SKReader, reader identifier, counter 1.
    private func encryptAsReader(_ plaintext: [UInt8]) throws -> [UInt8] {
        let nonce = try AES.GCM.Nonce(data: "000000000000000000000001".hexToBytes())
        let key = SymmetricKey(data: SessionTestVectors.bytes("skReader"))
        let sealed = try AES.GCM.seal(plaintext, using: key, nonce: nonce)
        return [UInt8](sealed.ciphertext) + [UInt8](sealed.tag)
    }
}
