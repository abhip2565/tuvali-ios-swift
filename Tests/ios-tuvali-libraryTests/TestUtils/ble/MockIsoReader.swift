import CoreBluetooth
import XCTest
@testable import ios_tuvali_library

/// Table 12 characteristics of the mdoc reader service (ISO 18013-5 clause 8.3.3.1.1.4).
let readerState = CBUUID(string: "00000005-a123-48ce-896b-4c76973373e6")
let readerClientToServer = CBUUID(string: "00000006-a123-48ce-896b-4c76973373e6")
let readerServerToClient = CBUUID(string: "00000007-a123-48ce-896b-4c76973373e6")
let readerIdent = CBUUID(string: "00000008-a123-48ce-896b-4c76973373e6")

/// A scripted ISO 18013-5 reader as seen through one GATT connection.
///
/// It serves the reader service with an Ident, records what the wallet subscribes to and writes
/// (in order, as [events]), and lets the test push chunked messages, End or a link drop. Its
/// chunking and reassembly are written independently of the production code.
final class MockIsoReader: GattClient, @unchecked Sendable {
    let peripheral = MockGattPeripheral()
    let ident: [UInt8]
    /// MTU − 3, the largest part either side writes or notifies.
    let partBytes: Int

    /// What the wallet did on this connection, e.g. "subscribe 05", "state 01", "unsubscribe 07", "close".
    private(set) var events: [String] = []
    private(set) var clientToServerParts: [[UInt8]] = []

    /// Set to make the matching step fail, e.g. a link drop while subscribing.
    var failOnConnect: Error?
    var failOnSubscribe: Error?
    var failOnIdentRead: Error?

    let notifications: AsyncThrowingStream<GattNotification, Error>
    private let notificationContinuation: AsyncThrowingStream<GattNotification, Error>.Continuation
    private let service: CBMutableService
    private var state: GattConnectionState = .connected

    init(serviceUuid: CBUUID, ident: [UInt8], partBytes: Int = 182, missingCharacteristic: CBUUID? = nil) {
        self.ident = ident
        self.partBytes = partBytes
        service = CBMutableService(type: serviceUuid, primary: true)
        service.characteristics = [readerState, readerClientToServer, readerServerToClient, readerIdent]
            .filter { $0 != missingCharacteristic }
            .map { CBMutableCharacteristic(type: $0, properties: [.notify], value: nil, permissions: []) }
        var streamContinuation: AsyncThrowingStream<GattNotification, Error>.Continuation?
        notifications = AsyncThrowingStream { streamContinuation = $0 }
        guard let continuation = streamContinuation else { preconditionFailure("Stream has no continuation") }
        notificationContinuation = continuation
    }

    var wasClosed: Bool { events.contains("close") }

    /// Called by the test's connect step: records the connection, or fails as scripted.
    func acceptConnection() throws -> MockIsoReader {
        if let failure = failOnConnect { throw failure }
        events.append("connect")
        return self
    }

    // MARK: GattClient

    func findService(_ serviceUuid: CBUUID) async throws -> CBService { service }

    func read(serviceUuid: CBUUID, characteristicUuid: CBUUID) async throws -> [UInt8] {
        if let failure = failOnIdentRead { throw failure }
        events.append("read ident")
        return ident
    }

    func writeWithoutResponse(serviceUuid: CBUUID, characteristicUuid: CBUUID, value: [UInt8]) async throws {
        try failIfDropped()
        if characteristicUuid == readerState { events.append("state \(value.hex)") }
        if characteristicUuid == readerClientToServer { clientToServerParts.append(value) }
    }

    func enableNotifications(serviceUuid: CBUUID, characteristicUuid: CBUUID) async throws {
        if let failure = failOnSubscribe { throw failure }
        events.append("subscribe \(shortName(characteristicUuid))")
    }

    func disableNotifications(serviceUuid: CBUUID, characteristicUuid: CBUUID) async throws {
        try failIfDropped()
        events.append("unsubscribe \(shortName(characteristicUuid))")
    }

    func currentConnectionState() async -> GattConnectionState { state }

    func currentMaximumWriteLength() async -> Int { partBytes }

    func close() {
        events.append("close")
        notificationContinuation.finish()
    }

    // MARK: what the test makes the reader do

    /// Notifies [message] on Server2Client in parts of partBytes with 0x01 / 0x00 headers.
    func sendMessage(_ message: [UInt8]) {
        let payloadPerPart = partBytes - 1
        let starts = message.isEmpty ? [0] : Array(stride(from: 0, to: message.count, by: payloadPerPart))
        for start in starts {
            let end = min(start + payloadPerPart, message.count)
            let header: UInt8 = end < message.count ? 0x01 : 0x00
            sendRawPart([header] + message[start..<end])
        }
    }

    func sendRawPart(_ part: [UInt8]) {
        notificationContinuation.yield(GattNotification(characteristicUuid: readerServerToClient, value: part))
    }

    /// A notification on any characteristic, e.g. one the transport should ignore.
    func sendNotification(on characteristicUuid: CBUUID, _ value: [UInt8]) {
        notificationContinuation.yield(GattNotification(characteristicUuid: characteristicUuid, value: value))
    }

    func sendState(_ value: UInt8) {
        notificationContinuation.yield(GattNotification(characteristicUuid: readerState, value: [value]))
    }

    func dropLink() {
        state = .lost(.remoteDisconnected)
        notificationContinuation.finish(throwing: GattDisconnectedError(reason: .remoteDisconnected))
    }

    /// The messages the wallet wrote to Client2Server, rebuilt from their parts.
    func receivedMessages() -> [[UInt8]] {
        var messages: [[UInt8]] = []
        var current: [UInt8] = []
        for part in clientToServerParts {
            current += part.dropFirst()
            if part.first == 0x00 {
                messages.append(current)
                current = []
            }
        }
        return messages
    }

    private func failIfDropped() throws {
        if state != .connected { throw GattDisconnectedError(reason: .remoteDisconnected) }
    }

    private func shortName(_ uuid: CBUUID) -> String {
        String(uuid.uuidString.lowercased().dropFirst(6).prefix(2))
    }
}

/// A ReaderFinder that hands out scripted readers in order and records what each scan excluded.
final class ScriptedReaderFinder: ReaderFinder, @unchecked Sendable {
    private var readersToFind: [MockIsoReader] = []
    private(set) var scanRequests: [Set<UUID>] = []
    private(set) var found: [UUID: MockIsoReader] = [:]

    func add(_ reader: MockIsoReader) {
        readersToFind.append(reader)
    }

    func findReader(serviceUuid: CBUUID, excluding excludedReaders: Set<UUID>) async throws -> GattPeripheral {
        scanRequests.append(excludedReaders)
        guard !readersToFind.isEmpty else { throw IsoTransportError("No more scripted readers") }
        let reader = readersToFind.removeFirst()
        found[reader.peripheral.identifier] = reader
        return reader.peripheral
    }

    /// The connect step for BleCentralTransport: the scripted reader behind [peripheral].
    func connect(_ peripheral: GattPeripheral) throws -> GattClient {
        guard let reader = found[peripheral.identifier] else { throw IsoTransportError("Unknown peripheral") }
        return try reader.acceptConnection()
    }
}
