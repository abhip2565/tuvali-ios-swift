import Foundation
@testable import ios_tuvali_library

/// An MdocTransport that hands out scripted reader events and records what the session sends, so
/// session and presenter tests need no Bluetooth at all. receive() waits while nothing is
/// scripted, like a real reader that stays silent.
final class ScriptedTransport: MdocTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let incomingContinuation: AsyncThrowingStream<ReaderEvent, Error>.Continuation
    private var incoming: AsyncThrowingStream<ReaderEvent, Error>.AsyncIterator
    private var sentMessages: [[UInt8]] = []
    private var isOpened = false
    private var isClosed = false
    private var isReaderFound = false
    private var recordedSteps: [String] = []

    /// Set to make every send fail, e.g. because the link is already gone.
    var failOnSend: Error?

    /// Set to make open() fail, e.g. Bluetooth switched off while scanning.
    var failOnOpen: Error?

    /// Set to make open() wait until readerFound() is called, like a scan that finds nobody yet.
    var waitForReader = false

    init(_ incomingEvents: ReaderEvent...) {
        var streamContinuation: AsyncThrowingStream<ReaderEvent, Error>.Continuation?
        let stream = AsyncThrowingStream<ReaderEvent, Error> { streamContinuation = $0 }
        guard let continuation = streamContinuation else { preconditionFailure("Stream has no continuation") }
        incomingContinuation = continuation
        incoming = stream.makeAsyncIterator()
        incomingEvents.forEach { continuation.yield($0) }
    }

    var sent: [[UInt8]] { locked { sentMessages } }
    var opened: Bool { locked { isOpened } }
    var closed: Bool { locked { isClosed } }
    /// The order in which receive() calls ended and close() was called, e.g. ["receive ended", "close"].
    var steps: [String] { locked { recordedSteps } }

    func queue(_ event: ReaderEvent) {
        incomingContinuation.yield(event)
    }

    /// The link drops: whatever is queued is still delivered, then receive() throws [failure].
    func dropLink(_ failure: Error) {
        incomingContinuation.finish(throwing: failure)
    }

    func readerFound() {
        locked { isReaderFound = true }
    }

    func open() async throws {
        if let failure = failOnOpen { throw failure }
        while waitForReader, !locked({ isReaderFound }) {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        locked { isOpened = true }
    }

    func send(_ message: [UInt8]) async throws {
        // like the GATT client, which fails every operation of a cancelled task
        try Task.checkCancellation()
        if let failure = failOnSend { throw failure }
        locked { sentMessages.append(message) }
    }

    func receive() async throws -> ReaderEvent {
        defer { locked { recordedSteps.append("receive ended") } }
        // one session task receives at a time, as with the real transport
        guard let event = try await incoming.next() else {
            try Task.checkCancellation()
            throw GattDisconnectedError(reason: nil)
        }
        return event
    }

    func close() async {
        locked {
            isClosed = true
            recordedSteps.append("close")
        }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
