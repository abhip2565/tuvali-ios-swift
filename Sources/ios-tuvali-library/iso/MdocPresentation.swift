import Foundation

/// How a presentation runs. [trustedReaderRoots] are DER-encoded root certificates for reader
/// authentication; with none, every validly signed request is reported as unverified.
public struct MdocPresentationOptions: Sendable {
    public var trustedReaderRoots: [Data]
    /// Seconds to wait for a reader to connect; clause 8.2.3 asks readers to wait at least 30 s.
    public var engagementTimeout: TimeInterval
    /// Seconds without activity before the session ends; clause 9.1.1.4 asks for at least 300 s.
    public var inactivityTimeout: TimeInterval

    public init(trustedReaderRoots: [Data] = [], engagementTimeout: TimeInterval = 60, inactivityTimeout: TimeInterval = 300) {
        self.trustedReaderRoots = trustedReaderRoots
        self.engagementTimeout = engagementTimeout
        self.inactivityTimeout = inactivityTimeout
    }
}

/// What the wallet is told and asked during a presentation. The async calls should return soon
/// after their task is cancelled (by MdocPresenter.cancel() or a time-out), since the presentation
/// waits for them before it ends.
public protocol MdocCallbacks: AnyObject {
    /// Show this text as a QR code (ISO/IEC 18004) for the reader to scan.
    func onQrReady(_ qrText: String) async throws

    /// Ask the holder about the reader's request and return their decision with the signed answer.
    func onRequest(_ request: MdocRequest) async throws -> MdocSharingDecision

    func onProgress(_ progress: MdocProgress)
}

extension MdocCallbacks {
    public func onProgress(_ progress: MdocProgress) {}
}

/// The holder's decision on one request.
public enum MdocSharingDecision: Equatable, Sendable {
    /// Send this DeviceResponse, built and signed by the wallet for the approved fields.
    case send(deviceResponse: Data)

    /// Share nothing; the session ends with status 20.
    case decline
}

/// One request from the reader. [requestNumber] is 1 for the first request and counts further ones
/// in the same session. [sessionTranscript] are the bytes the DeviceResponse must be signed over.
public struct MdocRequest: Equatable, Sendable {
    public let documents: [RequestedDocument]
    public let sessionTranscript: Data
    public let requestNumber: Int
}

/// One requested document: its type, the requested data elements per namespace with whether the
/// reader intends to keep each one, and how far the reader could be trusted.
public struct RequestedDocument: Equatable, Sendable {
    public let docType: String
    public let nameSpaces: [String: [String: Bool]]
    public let readerTrust: ReaderTrustStatus
}

/// The result of checking the reader's signature on a document request.
public enum ReaderTrustStatus: Equatable, Sendable {
    case notSigned
    case verified(readerName: String?)
    case unverified(readerName: String?, reason: String)
    case invalid(reason: String)
}

public enum MdocProgress: Equatable, Sendable {
    case waitingForReader
    case connected
    case requestReceived
    case sendingResponse
}

/// How a presentation ended.
public enum MdocResult: Equatable, Sendable {
    /// At least one answer was sent. [confirmedByReader] is false when the link dropped after the
    /// answer instead of the reader ending the session. Confirmation only means session
    /// termination, not that the reader accepted or verified the credentials.
    case completed(confirmedByReader: Bool)
    case declined
    case cancelled
    case failed(MdocFailure, detail: String?)
}

public enum MdocFailure: Equatable, Sendable {
    case bluetoothOff
    case noReaderFound
    case connectionFailed
    case connectionLost
    case timedOut
    case readerEnded
    case requestUnreadable
    case readerSecurityError
    /// The reader reported a session error (status 10 or 11), rather than a local failure.
    case readerReportedError(status: Int)
    case internalError
}

/// present() could not start a presentation.
public enum MdocPresentationError: Error, Equatable {
    /// Another presentation is running on this presenter.
    case alreadyRunning
    /// A trusted reader root is not a DER certificate.
    case invalidTrustedReaderRoot
    /// Timeouts must be finite, positive, and no longer than one year.
    case invalidTimeout
}
