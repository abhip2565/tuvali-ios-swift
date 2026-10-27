@preconcurrency import CoreBluetooth
import Foundation
import Security

private let logger = TaggedLogger(tag: "MdocPresenter")
// how long the cleanup may spend telling the reader and closing the connection
private let cleanupStepTimeout: TimeInterval = 2

/// Presents mdoc credentials to an ISO 18013-5 reader in person: shows the QR code, waits for the
/// reader to connect, hands each request to the wallet for consent, and sends the signed answer.
///
/// One presentation runs at a time. Every ending closes the connection and destroys the session
/// keys. The reader is told the session ends (status 20) only while it is still live: not after it
/// ended the session itself, and not after Tuvali already sent it an error status.
public final class MdocPresenter: @unchecked Sendable {
    private let createEngagement: () -> DeviceEngagement
    private let createTransport: (DeviceEngagement) throws -> MdocTransport
    private let now: () -> Date
    private let lock = NSLock()
    private var running: Task<MdocResult, Never>?

    /// A presenter on the device's Bluetooth. Bluetooth is first used when a presentation starts,
    /// so the permission prompt does not appear before then.
    public convenience init() {
        self.init(
            createEngagement: { DeviceEngagement.create() },
            createTransport: { engagement in try bluetoothTransport(for: engagement) },
            now: { Date() }
        )
    }

    init(
        createEngagement: @escaping () -> DeviceEngagement,
        createTransport: @escaping (DeviceEngagement) throws -> MdocTransport,
        now: @escaping () -> Date
    ) {
        self.createEngagement = createEngagement
        self.createTransport = createTransport
        self.now = now
    }

    /// Runs one presentation and returns how it ended. Throws MdocPresentationError if another one
    /// is running or a trusted reader root is not a DER certificate, and CancellationError if the
    /// calling task is cancelled (cancel() instead returns MdocResult.cancelled).
    public func present(options: MdocPresentationOptions, callbacks: MdocCallbacks) async throws -> MdocResult {
        try Task.checkCancellation()
        guard [options.engagementTimeout, options.inactivityTimeout].allSatisfy({
            $0.isFinite && $0 > 0 && $0 <= 365 * 24 * 60 * 60
        }) else { throw MdocPresentationError.invalidTimeout }
        let trustedRoots = try parseCertificates(options.trustedReaderRoots)
        let presentation: Task<MdocResult, Never> = try locked {
            guard running == nil else { throw MdocPresentationError.alreadyRunning }
            // its own task, so that cancel() can end it
            let started = Task { await self.runPresentation(options, callbacks, trustedRoots) }
            running = started
            return started
        }
        defer { locked { if running == presentation { running = nil } } }
        let result = await withTaskCancellationHandler {
            await presentation.value
        } onCancel: {
            presentation.cancel()
        }
        // cancel() cancels only the presentation; if our caller was cancelled, pass that on
        if result == .cancelled, Task.isCancelled { throw CancellationError() }
        return result
    }

    /// Ends the running presentation, if any; it then returns MdocResult.cancelled.
    public func cancel() {
        locked { running }?.cancel()
    }

    /// What has happened so far, to decide how the presentation ends.
    private final class Progress {
        var connected = false
        var sessionEnded = false
        var answered = false
    }

    private func runPresentation(
        _ options: MdocPresentationOptions,
        _ callbacks: MdocCallbacks,
        _ trustedRoots: [SecCertificate]
    ) async -> MdocResult {
        let engagement = createEngagement()
        let transport: MdocTransport
        do {
            transport = try createTransport(engagement)
        } catch {
            // nothing was opened yet; only the fresh key needs destroying
            engagement.deviceKey.wipe()
            return .failed(.internalError, detail: "\(error)")
        }
        let authenticator = ReaderAuthenticator(trustAnchors: trustedRoots, now: now)
        let session = MdocSession(transport: transport, engagement: engagement, readerAuthenticator: authenticator)
        let progress = Progress()
        let result: MdocResult
        do {
            result = try await exchange(engagement, transport, session, options, callbacks, progress)
        } catch {
            result = Task.isCancelled ? .cancelled : resultFor(error, progress)
        }
        // a new task does not inherit this one's cancellation, so the cleanup still reaches the reader
        await Task { await self.endPresentation(session, transport, progress) }.value
        logger.info("Presentation ended")
        return result
    }

    private func exchange(
        _ engagement: DeviceEngagement,
        _ transport: MdocTransport,
        _ session: MdocSession,
        _ options: MdocPresentationOptions,
        _ callbacks: MdocCallbacks,
        _ progress: Progress
    ) async throws -> MdocResult {
        try Task.checkCancellation()
        callbacks.onProgress(.waitingForReader)
        try await callbacks.onQrReady(try engagement.toQrText())
        guard try await withTimeout(options.engagementTimeout, { try await transport.open() }) != nil else {
            return .failed(.noReaderFound, detail: "No reader connected in time")
        }
        progress.connected = true
        callbacks.onProgress(.connected)

        var requestNumber = 0
        while true {
            let received = try await sessionStep(progress) {
                try await withTimeout(options.inactivityTimeout) { try await session.receiveRequest() }
            }
            guard let event = received else { return .failed(.timedOut, detail: "The reader sent nothing in time") }
            switch event {
            case let .ended(status):
                progress.sessionEnded = true
                if let status = status, status != SessionStatus.sessionTermination {
                    let failure: MdocFailure = SessionData.statusesWithoutData.contains(status)
                        ? .readerReportedError(status: status) : .readerEnded
                    return .failed(failure, detail: "Reader ended with session status \(status)")
                }
                guard progress.answered else {
                    return .failed(.readerEnded, detail: "The reader ended the session without a request")
                }
                return .completed(confirmedByReader: true)
            case let .request(deviceRequest):
                requestNumber += 1
                callbacks.onProgress(.requestReceived)
                guard let transcript = session.sessionTranscriptBytes() else {
                    preconditionFailure("A request comes only after the session transcript is known")
                }
                let request = mdocRequest(deviceRequest, transcript, requestNumber)
                let decided = try await withTimeout(options.inactivityTimeout) { try await callbacks.onRequest(request) }
                guard let decision = decided else {
                    return .failed(.timedOut, detail: "The holder did not decide in time")
                }
                switch decision {
                case let .send(deviceResponse):
                    callbacks.onProgress(.sendingResponse)
                    try await sessionStep(progress) { try await session.respond([UInt8](deviceResponse)) }
                    progress.answered = true
                case .decline:
                    try await sessionStep(progress) { try await session.terminate() }
                    progress.sessionEnded = true
                    return .declined
                }
            }
        }
    }

    /// Runs a step of the session itself. If it fails, the session has already told the reader why
    /// (status 10 or 11) or the link is gone, so the cleanup must not send status 20 on top.
    private func sessionStep<T>(_ progress: Progress, _ step: () async throws -> T) async throws -> T {
        do {
            return try await step()
        } catch {
            if !Task.isCancelled { progress.sessionEnded = true }
            throw error
        }
    }

    private func endPresentation(_ session: MdocSession, _ transport: MdocTransport, _ progress: Progress) async {
        if progress.connected, !progress.sessionEnded {
            do {
                _ = try await withTimeout(cleanupStepTimeout) { try await session.terminate() }
            } catch {
                logger.warning("Could not tell the reader the session ends: \(error)")
            }
        }
        _ = try? await withTimeout(cleanupStepTimeout) { await transport.close() }
        session.wipe()
    }

    private func resultFor(_ failure: Error, _ progress: Progress) -> MdocResult {
        let detail = "\(failure)"
        switch failure {
        case let disconnected as GattDisconnectedError:
            if progress.answered { return .completed(confirmedByReader: false) }
            if disconnected.reason == .bluetoothTurnedOff { return .failed(.bluetoothOff, detail: detail) }
            return .failed(.connectionLost, detail: detail)
        case is BleScanFailedError, is GattError:
            return .failed(.connectionFailed, detail: detail)
        case is IsoTransportError, is CborDecodingError, is SessionProtocolError:
            return .failed(.requestUnreadable, detail: detail)
        case is InvalidReaderKeyError, is SessionDecryptionError:
            return .failed(.readerSecurityError, detail: detail)
        default:
            return .failed(.internalError, detail: detail)
        }
    }

    private func mdocRequest(_ deviceRequest: DeviceRequest, _ sessionTranscript: [UInt8], _ requestNumber: Int) -> MdocRequest {
        MdocRequest(
            documents: deviceRequest.docRequests.map { docRequest in
                RequestedDocument(
                    docType: docRequest.docType,
                    nameSpaces: docRequest.nameSpaces,
                    readerTrust: trustStatus(docRequest.readerTrust)
                )
            },
            sessionTranscript: Data(sessionTranscript),
            requestNumber: requestNumber
        )
    }

    private func trustStatus(_ trust: ReaderTrust) -> ReaderTrustStatus {
        switch trust {
        case .notSigned: return .notSigned
        case let .verified(readerName, _): return .verified(readerName: readerName)
        case let .unverified(readerName, _, reason): return .unverified(readerName: readerName, reason: reason)
        case let .invalid(reason): return .invalid(reason: reason)
        }
    }

    private func parseCertificates(_ derCertificates: [Data]) throws -> [SecCertificate] {
        try derCertificates.map { der in
            guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
                throw MdocPresentationError.invalidTrustedReaderRoot
            }
            return certificate
        }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

/// The transport for the engagement's retrieval method: BLE with the mdoc as central client today.
/// The central is created here, per presentation: creating it is what asks for Bluetooth permission.
private func bluetoothTransport(for engagement: DeviceEngagement) throws -> MdocTransport {
    guard engagement.retrievalMethods.count == 1, let method = engagement.retrievalMethods.first else {
        throw IsoTransportStateError("The engagement must offer exactly one retrieval method")
    }
    switch method {
    case let .bleCentralClient(uuid):
        let central = AsyncBleCentral()
        return BleCentralTransport(
            serviceUuid: CBUUID(nsuuid: uuid),
            expectedIdent: bleIdent(engagement.eDeviceKeyBytes),
            readerFinder: BleReaderFinder(central: central),
            connect: { peripheral in try await central.connect(peripheral) }
        )
    }
}
