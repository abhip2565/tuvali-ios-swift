private let logger = TaggedLogger(tag: "MdocSession")
// the free function, under another name: inside MdocSession its own accessor of the same name wins
private let buildSessionTranscriptBytes = sessionTranscriptBytes(deviceEngagementBytes:readerCoseKey:handover:)

/// What the reader did: sent a request, or ended the session (with its status, if it sent one).
enum SessionEvent: Equatable {
    case request(DeviceRequest)
    case ended(status: Int?)
}

/// One ISO 18013-5 session over any MdocTransport (clause 9.1.1.4 steps 2 to 4).
///
/// The first message must be a SessionEstablishment, which sets up session encryption from the
/// reader's key; later requests come in SessionData. When a message cannot be used, the reader is
/// told why before the error is thrown: status 10 for a bad reader key, a message that does not
/// decrypt, or an attempt to re-establish the session (it is never re-keyed); status 11 for
/// anything that is not the expected CBOR or comes in the wrong order. Each requested document
/// carries the result of checking its reader authentication with [readerAuthenticator]. Whether to
/// answer a further request is the caller's decision.
///
/// One session task owns an instance, as with the transport below it.
final class MdocSession {
    private let transport: MdocTransport
    private let engagement: DeviceEngagement
    private let handover: Handover
    private let readerAuthenticator: ReaderAuthenticator
    private var encryption: SessionEncryption?
    private var sessionTranscript: [UInt8]?

    init(
        transport: MdocTransport,
        engagement: DeviceEngagement,
        handover: Handover = .qr,
        readerAuthenticator: ReaderAuthenticator = ReaderAuthenticator()
    ) {
        self.transport = transport
        self.engagement = engagement
        self.handover = handover
        self.readerAuthenticator = readerAuthenticator
    }

    /// Waits for the reader's next request, or for it to end the session.
    func receiveRequest() async throws -> SessionEvent {
        let message: [UInt8]
        switch try await transport.receive() {
        case .ended: return .ended(status: nil)
        case let .message(bytes): message = bytes
        }

        let received = try await tellReaderOnFailure(SessionStatus.cborDecodingError) {
            try SessionMessage.decode(message)
        }
        let encryptedRequest: [UInt8]
        switch received {
        case let .establishment(establishment):
            if encryption != nil {
                try await rejectOnProtocolViolation(SessionStatus.encryptionError, "Reader tried to re-establish the session")
            }
            encryptedRequest = try await establishSession(establishment)
        case let .data(sessionData):
            guard encryption != nil else {
                try await rejectOnProtocolViolation(
                    SessionStatus.cborDecodingError,
                    "First message must be a SessionEstablishment"
                )
            }
            if let status = sessionData.status { return .ended(status: status) }
            guard let data = sessionData.data else {
                try await rejectOnProtocolViolation(
                    SessionStatus.cborDecodingError,
                    "SessionData has neither data nor status"
                )
            }
            encryptedRequest = data
        }

        guard let sessionEncryption = encryption, let transcript = sessionTranscript else {
            preconditionFailure("The session is established before a request is decrypted")
        }
        let plaintext = try await tellReaderOnFailure(SessionStatus.encryptionError) {
            try sessionEncryption.decryptFromReader(encryptedRequest)
        }
        let authenticator = readerAuthenticator
        let request = try await tellReaderOnFailure(SessionStatus.cborDecodingError) {
            try DeviceRequest.decode(plaintext) { readerAuth, itemsRequestBytes in
                authenticator.check(readerAuth, sessionTranscriptBytes: transcript, itemsRequestBytes: itemsRequestBytes)
            }
        }
        return .request(request)
    }

    /// SessionTranscriptBytes of this session, once the reader's first message arrived. The wallet
    /// needs them to sign the DeviceResponse (mdoc authentication covers the transcript).
    func sessionTranscriptBytes() -> [UInt8]? {
        sessionTranscript
    }

    /// Sends the encrypted DeviceResponse (built and signed outside Tuvali).
    func respond(_ deviceResponse: [UInt8]) async throws {
        guard let sessionEncryption = encryption else {
            throw SessionEncryptionStateError("No request has been received")
        }
        try await transport.send(SessionData(data: try sessionEncryption.encryptForReader(deviceResponse)).encode())
    }

    /// Tells the reader the mdoc ends the session (status 20).
    func terminate() async throws {
        try await transport.send(SessionData(status: SessionStatus.sessionTermination).encode())
    }

    /// Destroys the session keys and the ephemeral device key (clause 9.1.1.4 step 4).
    func wipe() {
        encryption?.wipe()
        engagement.deviceKey.wipe()
    }

    private func establishSession(_ establishment: SessionEstablishment) async throws -> [UInt8] {
        let transcript = buildSessionTranscriptBytes(engagement.bytes, establishment.readerCoseKey, handover)
        let deviceKey = engagement.deviceKey
        encryption = try await tellReaderOnFailure(SessionStatus.encryptionError) {
            try SessionEncryption.establish(
                deviceKey: deviceKey,
                readerCoseKey: establishment.readerCoseKey,
                sessionTranscriptBytes: transcript
            )
        }
        sessionTranscript = transcript
        return establishment.data
    }

    /// The reader broke the session order: tell it [status] (best effort) and end the session with [reason].
    private func rejectOnProtocolViolation(_ status: Int, _ reason: String) async throws -> Never {
        await sendStatusBestEffortToReader(status)
        throw SessionProtocolError(reason)
    }

    private func sendStatusBestEffortToReader(_ status: Int) async {
        do {
            try await transport.send(SessionData(status: status).encode())
        } catch {
            logger.warning("Could not send status \(status) to the reader: \(error)")
        }
    }

    /// Runs [step]; if it fails, sends [status] to the reader (best effort) and rethrows.
    private func tellReaderOnFailure<T>(_ status: Int, _ step: () throws -> T) async throws -> T {
        do {
            return try step()
        } catch {
            await sendStatusBestEffortToReader(status)
            throw error
        }
    }
}
