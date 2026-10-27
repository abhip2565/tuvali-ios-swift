import XCTest
@testable import ios_tuvali_library

/// The public presentation flow: engagement, request, consent, answer and every way it can end.
final class MdocPresenterTests: XCTestCase {
    private var deviceKey: EphemeralDeviceKey!
    private var transport: ScriptedTransport!
    private var presenter: MdocPresenter!
    private let options = MdocPresentationOptions(engagementTimeout: 60, inactivityTimeout: 300)
    private let deviceResponse = Data(SessionTestVectors.bytes("session.deviceResponse"))

    override func setUpWithError() throws {
        // the fixed engagement of the test vectors, so the scripted reader's messages decrypt
        deviceKey = try EphemeralDeviceKey.fromPrivateScalar(SessionTestVectors.bytes("deviceKey.privateScalar"))
        let uuid = try XCTUnwrap(UUID(uuidString: SessionTestVectors.string("bleClientUuid")))
        let engagement = DeviceEngagement.create(deviceKey: deviceKey, retrievalMethods: [.bleCentralClient(uuid: uuid)])
        let validationTime = try XCTUnwrap(ISO8601DateFormatter().date(from: SessionTestVectors.string("readerAuth.validationTime")))
        let scripted = ScriptedTransport()
        transport = scripted
        presenter = MdocPresenter(createEngagement: { engagement }, createTransport: { _ in scripted }, now: { validationTime })
    }

    private func message(_ name: String) -> ReaderEvent {
        .message(SessionTestVectors.bytes("session.\(name)"))
    }

    private func vectorHex(_ name: String) -> String {
        SessionTestVectors.string("session.\(name)")
    }

    private func failure(of result: MdocResult) -> MdocFailure? {
        guard case let .failed(failure, _) = result else { return nil }
        return failure
    }

    private func startPresenting(
        _ callbacks: RecordingCallbacks,
        options: MdocPresentationOptions? = nil
    ) -> Task<MdocResult, Error> {
        let presenter = presenter!
        let chosen = options ?? self.options
        return Task { try await presenter.present(options: chosen, callbacks: callbacks) }
    }


    func testRejectsInvalidTimeoutsBeforeOpeningBluetooth() async {
        for value in [TimeInterval.nan, .infinity, -.infinity, -1, 0, .greatestFiniteMagnitude] {
            var invalid = options
            invalid.engagementTimeout = value
            do {
                _ = try await presenter.present(options: invalid, callbacks: RecordingCallbacks())
                XCTFail("Accepted invalid timeout")
            } catch {
                XCTAssertEqual(error as? MdocPresentationError, .invalidTimeout)
            }
        }
        XCTAssertFalse(transport.opened)
    }

    func testReaderErrorAfterResponseIsNotReportedAsSuccess() async throws {
        transport.queue(message("sessionEstablishment"))
        transport.queue(.message(SessionData(status: SessionStatus.encryptionError).encode()))
        let result = try await presenter.present(options: options, callbacks: RecordingCallbacks(answer: deviceResponse))
        XCTAssertEqual(failure(of: result), .readerReportedError(status: SessionStatus.encryptionError))
        XCTAssertEqual(transport.sent.count, 1)
        XCTAssertTrue(transport.closed)
    }

    func testReaderCborErrorAfterResponseHasItsOwnFailureAndNoSecondTermination() async throws {
        transport.queue(message("sessionEstablishment"))
        transport.queue(.message(SessionData(status: SessionStatus.cborDecodingError).encode()))
        let result = try await presenter.present(options: options, callbacks: RecordingCallbacks(answer: deviceResponse))
        XCTAssertEqual(failure(of: result), .readerReportedError(status: SessionStatus.cborDecodingError))
        XCTAssertEqual(transport.sent.count, 1)
        XCTAssertTrue(transport.closed)
    }

    func testReaderNormalTerminationAfterResponseRemainsConfirmed() async throws {
        transport.queue(message("sessionEstablishment"))
        transport.queue(.message(SessionData(status: SessionStatus.sessionTermination).encode()))
        let result = try await presenter.present(options: options, callbacks: RecordingCallbacks(answer: deviceResponse))
        XCTAssertEqual(result, .completed(confirmedByReader: true))
        XCTAssertEqual(transport.sent.count, 1)
    }

    // MARK: the normal flow

    func testPresentShowsTheQrTextOfTheEngagement() async throws {
        let callbacks = RecordingCallbacks()
        transport.queue(.ended)

        _ = try await presenter.present(options: options, callbacks: callbacks)

        XCTAssertEqual(callbacks.qrTexts, [SessionTestVectors.string("qrText")])
    }

    func testPresentHandsEveryRequestedDocumentItsFieldsAndTheSessionTranscriptToOnRequest() async throws {
        let callbacks = RecordingCallbacks(answer: deviceResponse)
        transport.queue(message("sessionEstablishment"))
        transport.queue(.ended)

        _ = try await presenter.present(options: options, callbacks: callbacks)

        let request = try XCTUnwrap(callbacks.requests.first)
        XCTAssertEqual(callbacks.requests.count, 1)
        XCTAssertEqual(request.documents.map(\.docType), ["org.iso.18013.5.1.mDL", "org.example.test.1"])
        let mdlElements = request.documents[0].nameSpaces["org.iso.18013.5.1"]
        XCTAssertEqual(mdlElements, ["family_name": true, "portrait": false, "age_over_18": false])
        XCTAssertEqual([UInt8](request.sessionTranscript).hex, SessionTestVectors.string("sessionTranscriptBytes"))
        XCTAssertEqual(request.requestNumber, 1)
    }

    func testPresentSendsTheWalletsResponseAndCompletesWhenTheReaderEnds() async throws {
        transport.queue(message("sessionEstablishment"))
        transport.queue(.ended)

        let result = try await presenter.present(options: options, callbacks: RecordingCallbacks(answer: deviceResponse))

        XCTAssertEqual(transport.sent.map(\.hex), [vectorHex("responseSessionData")])
        XCTAssertEqual(result, .completed(confirmedByReader: true))
    }

    func testPresentAsksTheHolderAgainForAFurtherRequest() async throws {
        let callbacks = RecordingCallbacks(answer: deviceResponse)
        transport.queue(message("sessionEstablishment"))
        transport.queue(message("secondRequestSessionData"))
        transport.queue(.ended)

        _ = try await presenter.present(options: options, callbacks: callbacks)

        XCTAssertEqual(callbacks.requests.map(\.requestNumber), [1, 2])
        XCTAssertEqual(transport.sent.count, 2)
    }

    func testPresentSendsStatus20AndReturnsDeclinedWhenTheHolderDeclines() async throws {
        transport.queue(message("sessionEstablishment"))

        let result = try await presenter.present(options: options, callbacks: RecordingCallbacks { _ in .decline })

        XCTAssertEqual(result, .declined)
        XCTAssertEqual(transport.sent.map(\.hex), [vectorHex("statusTermination")])
    }

    func testPresentReportsTheReadersTrustForEachDocument() async throws {
        let callbacks = RecordingCallbacks(answer: deviceResponse)
        transport.queue(.message(SessionTestVectors.bytes("readerAuth.signedSessionEstablishment")))
        transport.queue(.ended)
        var withRoots = options
        withRoots.trustedReaderRoots = [Data(SessionTestVectors.bytes("readerAuth.rootCertificate"))]

        _ = try await presenter.present(options: withRoots, callbacks: callbacks)

        let trust = callbacks.requests.first?.documents.first?.readerTrust
        XCTAssertEqual(trust, .verified(readerName: "Tuvali Test Reader"))
    }

    func testPresentReportsProgressFromWaitingForAReaderToSendingTheResponse() async throws {
        let callbacks = RecordingCallbacks(answer: deviceResponse)
        transport.queue(message("sessionEstablishment"))
        transport.queue(.ended)

        _ = try await presenter.present(options: options, callbacks: callbacks)

        XCTAssertEqual(callbacks.progress, [.waitingForReader, .connected, .requestReceived, .sendingResponse])
    }

    // MARK: timeouts

    func testPresentReturnsNoReaderFoundWhenNoReaderConnectsWithinTheEngagementTimeout() async throws {
        transport.waitForReader = true
        let shortEngagement = MdocPresentationOptions(engagementTimeout: 0.1)

        let result = try await presenter.present(options: shortEngagement, callbacks: RecordingCallbacks())

        XCTAssertEqual(failure(of: result), .noReaderFound)
    }

    func testPresentReturnsTimedOutAndSendsStatus20WhenTheHolderDoesNotDecideWithinTheInactivityTimeout() async throws {
        transport.queue(message("sessionEstablishment"))
        let shortInactivity = MdocPresentationOptions(inactivityTimeout: 0.1)

        let result = try await presenter.present(options: shortInactivity, callbacks: RecordingCallbacks.undecided())

        XCTAssertEqual(failure(of: result), .timedOut)
        XCTAssertEqual(transport.sent.map(\.hex), [vectorHex("statusTermination")])
    }

    func testPresentReturnsTimedOutWhenTheReaderSendsNothingWithinTheInactivityTimeout() async throws {
        let shortInactivity = MdocPresentationOptions(inactivityTimeout: 0.1)

        let result = try await presenter.present(options: shortInactivity, callbacks: RecordingCallbacks())

        XCTAssertEqual(failure(of: result), .timedOut)
    }

    // MARK: cancel

    func testCancelWhileWaitingForAReaderReturnsCancelled() async throws {
        transport.waitForReader = true
        let callbacks = RecordingCallbacks()
        let presenting = startPresenting(callbacks)
        try await eventually { !callbacks.qrTexts.isEmpty }

        presenter.cancel()

        let result = try await presenting.value
        XCTAssertEqual(result, .cancelled)
        XCTAssertTrue(transport.sent.isEmpty)
    }

    func testCancelWhileTheHolderDecidesSendsStatus20AndReturnsCancelled() async throws {
        transport.queue(message("sessionEstablishment"))
        let callbacks = RecordingCallbacks.undecided()
        let presenting = startPresenting(callbacks)
        try await eventually { !callbacks.requests.isEmpty }

        presenter.cancel()

        let result = try await presenting.value
        XCTAssertEqual(result, .cancelled)
        XCTAssertEqual(transport.sent.map(\.hex), [vectorHex("statusTermination")])
    }

    func testCancelWhileWaitingForARequestLetsThePendingReceiveFinishBeforeClosing() async throws {
        let callbacks = RecordingCallbacks()
        let presenting = startPresenting(callbacks)
        try await eventually { callbacks.progress.contains(.connected) }

        presenter.cancel()

        _ = try await presenting.value
        XCTAssertEqual(transport.steps, ["receive ended", "close"])
        XCTAssertEqual(transport.sent.map(\.hex), [vectorHex("statusTermination")])
    }

    func testPresentThrowsCancellationErrorWhenTheCallingTaskIsCancelled() async throws {
        transport.waitForReader = true
        let callbacks = RecordingCallbacks()
        let presenting = startPresenting(callbacks)
        try await eventually { !callbacks.qrTexts.isEmpty }

        presenting.cancel()

        let failure = await errorThrown(by: presenting)
        XCTAssertTrue(failure is CancellationError, "\(String(describing: failure))")
        XCTAssertTrue(transport.closed)
    }

    // MARK: the connection and the reader failing

    func testPresentReturnsBluetoothOffWhenBluetoothIsSwitchedOffWhileLookingForAReader() async throws {
        transport.failOnOpen = GattDisconnectedError(reason: .bluetoothTurnedOff)

        let result = try await presenter.present(options: options, callbacks: RecordingCallbacks())

        XCTAssertEqual(failure(of: result), .bluetoothOff)
    }

    func testPresentReturnsConnectionLostWhenTheLinkDropsBeforeTheRequest() async throws {
        transport.dropLink(GattDisconnectedError(reason: .remoteDisconnected))

        let result = try await presenter.present(options: options, callbacks: RecordingCallbacks())

        XCTAssertEqual(failure(of: result), .connectionLost)
    }

    func testPresentCompletesWithoutTheReadersConfirmationWhenTheLinkDropsRightAfterTheAnswer() async throws {
        transport.queue(message("sessionEstablishment"))
        transport.dropLink(GattDisconnectedError(reason: .remoteDisconnected))

        let result = try await presenter.present(options: options, callbacks: RecordingCallbacks(answer: deviceResponse))

        XCTAssertEqual(result, .completed(confirmedByReader: false))
    }

    func testPresentReturnsReaderSecurityErrorForARequestThatDoesNotDecryptWithoutASecondStatus() async throws {
        var tampered = SessionTestVectors.bytes("session.sessionEstablishment")
        tampered[tampered.count - 1] &+= 1
        transport.queue(.message(tampered))

        let result = try await presenter.present(options: options, callbacks: RecordingCallbacks())

        XCTAssertEqual(failure(of: result), .readerSecurityError)
        // only the session's status 10, no status 20 on top
        XCTAssertEqual(transport.sent.map(\.hex), [vectorHex("statusEncryptionError")])
    }

    func testPresentReturnsRequestUnreadableForAMessageThatIsNotCborWithoutASecondStatus() async throws {
        transport.queue(.message("a2".hexToBytes()))

        let result = try await presenter.present(options: options, callbacks: RecordingCallbacks())

        XCTAssertEqual(failure(of: result), .requestUnreadable)
        XCTAssertEqual(transport.sent.map(\.hex), [vectorHex("statusCborError")])
    }

    func testPresentReturnsReaderEndedWhenTheReaderEndsBeforeSendingARequest() async throws {
        transport.queue(.ended)

        let result = try await presenter.present(options: options, callbacks: RecordingCallbacks())

        XCTAssertEqual(failure(of: result), .readerEnded)
        XCTAssertTrue(transport.sent.isEmpty)
    }

    func testPresentReturnsInternalErrorAndSendsStatus20WhenTheWalletsOnRequestFails() async throws {
        transport.queue(message("sessionEstablishment"))
        let failing = RecordingCallbacks { _ in throw SigningFailed() }

        let result = try await presenter.present(options: options, callbacks: failing)

        XCTAssertEqual(failure(of: result), .internalError)
        XCTAssertEqual(transport.sent.map(\.hex), [vectorHex("statusTermination")])
    }

    // MARK: cleanup and misuse

    func testPresentAlwaysClosesTheTransportAndWipesTheDeviceKey() async throws {
        transport.queue(message("sessionEstablishment"))
        transport.queue(.ended)

        _ = try await presenter.present(options: options, callbacks: RecordingCallbacks(answer: deviceResponse))

        XCTAssertTrue(transport.closed)
        XCTAssertThrowsError(try deviceKey.requirePrivateKey(), ofType: DeviceKeyWipedError.self)
    }

    func testPresentReturnsInternalErrorAndWipesTheDeviceKeyWhenTheTransportCannotBeCreated() async throws {
        let engagement = DeviceEngagement.create(deviceKey: deviceKey, retrievalMethods: [])
        let failing = MdocPresenter(
            createEngagement: { engagement },
            createTransport: { _ in throw IsoTransportStateError("no transport") },
            now: { Date() }
        )

        let result = try await failing.present(options: options, callbacks: RecordingCallbacks())

        XCTAssertEqual(failure(of: result), .internalError)
        XCTAssertThrowsError(try deviceKey.requirePrivateKey(), ofType: DeviceKeyWipedError.self)
    }

    func testPresentThrowsAlreadyRunningWhileAnotherPresentationIsRunning() async throws {
        transport.waitForReader = true
        let callbacks = RecordingCallbacks()
        let first = startPresenting(callbacks)
        try await eventually { !callbacks.qrTexts.isEmpty }

        let failure = await errorThrown(by: startPresenting(RecordingCallbacks()))

        XCTAssertEqual(failure as? MdocPresentationError, .alreadyRunning)
        presenter.cancel()
        _ = try await first.value
    }

    func testPresentCanRunAgainOnceTheLastPresentationEnded() async throws {
        transport.queue(.ended)
        _ = try await presenter.present(options: options, callbacks: RecordingCallbacks())

        let result = try await presenter.present(options: MdocPresentationOptions(inactivityTimeout: 0.1), callbacks: RecordingCallbacks())

        XCTAssertEqual(failure(of: result), .timedOut)
    }

    func testPresentThrowsInvalidTrustedReaderRootWhenATrustedReaderRootIsNotACertificate() async {
        var broken = options
        broken.trustedReaderRoots = [Data([1, 2, 3])]

        let failure = await errorThrown(by: Task { [presenter] in
            try await presenter!.present(options: broken, callbacks: RecordingCallbacks())
        })

        XCTAssertEqual(failure as? MdocPresentationError, .invalidTrustedReaderRoot)
    }
}

/// An error of the wallet's own, e.g. from signing the DeviceResponse.
private struct SigningFailed: Error {}

/// Records what the presenter told the wallet, and answers every request with [decide].
private final class RecordingCallbacks: MdocCallbacks, @unchecked Sendable {
    private let lock = NSLock()
    private let decide: (MdocRequest) async throws -> MdocSharingDecision
    private var recordedQrTexts: [String] = []
    private var recordedRequests: [MdocRequest] = []
    private var recordedProgress: [MdocProgress] = []

    init(decide: @escaping (MdocRequest) async throws -> MdocSharingDecision = { _ in .decline }) {
        self.decide = decide
    }

    convenience init(answer deviceResponse: Data) {
        self.init { _ in .send(deviceResponse: deviceResponse) }
    }

    /// A holder who never decides; only a cancel or a time-out ends the wait.
    static func undecided() -> RecordingCallbacks {
        RecordingCallbacks { _ in
            try await Task.sleep(nanoseconds: 3_600_000_000_000)
            return .decline
        }
    }

    var qrTexts: [String] { locked { recordedQrTexts } }
    var requests: [MdocRequest] { locked { recordedRequests } }
    var progress: [MdocProgress] { locked { recordedProgress } }

    func onQrReady(_ qrText: String) async throws {
        locked { recordedQrTexts.append(qrText) }
    }

    func onRequest(_ request: MdocRequest) async throws -> MdocSharingDecision {
        locked { recordedRequests.append(request) }
        return try await decide(request)
    }

    func onProgress(_ progress: MdocProgress) {
        locked { recordedProgress.append(progress) }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
