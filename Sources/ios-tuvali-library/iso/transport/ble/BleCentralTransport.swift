@preconcurrency import CoreBluetooth
import Foundation

private let logger = TaggedLogger(tag: "BleCentralTransport")
private typealias Characteristics = MdocReaderServiceCharacteristics
/// How many connections open() tries while the link keeps dropping before Start.
private let defaultMaxConnectAttempts = 3

/// The largest attribute value BLE allows, and so the largest part, whatever iOS reports.
private let largestAttributeValueBytes = 512

/// The ISO 18013-5 BLE transport with the mdoc as GATT client (clauses 8.3.3.1.1.3 to 8.3.3.1.1.8).
///
/// open() finds the reader advertising [serviceUuid], checks its Ident against [expectedIdent]
/// (leaving a reader that does not match and scanning on), subscribes to State and Server2Client
/// and writes Start. iOS negotiates the MTU itself; the part size is what it reports. A link lost
/// before Start is retried with a new connection; after Start nothing reconnects, and any failure
/// ends the session. A GATT timeout is never retried on the same connection, since a late answer
/// could be mistaken for the retry's.
///
/// Only notifications from State and Server2Client are read: on iOS a late read answer arrives
/// like a notification.
///
/// One session owns an instance; send and receive are meant to be called from that session.
final class BleCentralTransport: MdocTransport {
    private let serviceUuid: CBUUID
    private let expectedIdent: [UInt8]
    private let readerFinder: ReaderFinder
    private let connect: (GattPeripheral) async throws -> GattClient
    private let maxConnectAttempts: Int

    private var client: GattClient?
    private var chunker: IsoChunker?
    private var notifications: AsyncThrowingStream<GattNotification, Error>.AsyncIterator?
    private var readerEnded = false

    init(
        serviceUuid: CBUUID,
        expectedIdent: [UInt8],
        readerFinder: ReaderFinder,
        connect: @escaping (GattPeripheral) async throws -> GattClient,
        maxConnectAttempts: Int = defaultMaxConnectAttempts
    ) {
        self.serviceUuid = serviceUuid
        self.expectedIdent = expectedIdent
        self.readerFinder = readerFinder
        self.connect = connect
        self.maxConnectAttempts = maxConnectAttempts
    }

    func open() async throws {
        guard client == nil else { throw IsoTransportStateError("Transport is already open") }
        var excludedReaders: Set<UUID> = []
        // only connections lost before Start count; readers left for a wrong Ident do not
        var lostConnections = 0

        while true {
            let peripheral = try await readerFinder.findReader(serviceUuid: serviceUuid, excluding: excludedReaders)
            var candidate: GattClient?
            do {
                let connected = try await connect(peripheral)
                candidate = connected
                guard try await isExpectedReader(connected) else {
                    logger.info("Ident of a reader does not match; scanning on")
                    connected.close()
                    excludedReaders.insert(peripheral.identifier)
                    continue
                }
                try await subscribe(connected, to: Characteristics.state)
                try await subscribe(connected, to: Characteristics.serverToClient)
                let partBytes = min(await connected.currentMaximumWriteLength(), largestAttributeValueBytes)
                try await writeState(connected, ConnectionStateValue.start)
                chunker = try BleChunker(maximumPartBytes: partBytes)
                notifications = connected.notifications.makeAsyncIterator()
                client = connected
                return
            } catch {
                candidate?.close()
                guard isLostBeforeStart(error) else { throw error }
                lostConnections += 1
                guard lostConnections < maxConnectAttempts else { throw error }
                logger.info("Link lost before Start (\(lostConnections) of \(maxConnectAttempts)); connecting again")
            }
        }
    }

    /// Sends one whole message to the reader on Client2Server, split into parts.
    func send(_ message: [UInt8]) async throws {
        guard let openClient = client, let openChunker = chunker else {
            throw IsoTransportStateError("Transport is not open")
        }
        guard !readerEnded else { throw IsoTransportStateError("Reader already ended the session") }
        for part in openChunker.split(message) {
            try await openClient.writeWithoutResponse(
                serviceUuid: serviceUuid,
                characteristicUuid: Characteristics.clientToServer,
                value: part
            )
        }
    }

    /// Waits for the reader's next whole message, or End. Throws if the link drops while waiting.
    func receive() async throws -> ReaderEvent {
        guard client != nil, let openChunker = chunker, var iterator = notifications else {
            throw IsoTransportStateError("Transport is not open")
        }
        // the iterator is a value; keep where it got to for the next call
        defer { notifications = iterator }
        while true {
            guard let notification = try await iterator.next() else {
                // the stream also ends, without an error, when the waiting task is cancelled
                try Task.checkCancellation()
                throw GattDisconnectedError(reason: nil)
            }
            switch notification.characteristicUuid {
            case Characteristics.state where notification.value == [ConnectionStateValue.end]:
                readerEnded = true
                return .ended
            case Characteristics.serverToClient:
                if let message = try openChunker.addPiece(notification.value) { return .message(message) }
            default:
                // other State values, and notifications from any other characteristic
                continue
            }
        }
    }

    /// Ends the connection (clause 8.3.3.1.1.7): writes End unless the reader already did,
    /// unsubscribes from State and Server2Client, and disconnects. Each step is best effort, so a
    /// lost link still ends in a closed client.
    func close() async {
        guard let openClient = client else { return }
        client = nil
        chunker = nil
        notifications = nil
        let linkUp = await openClient.currentConnectionState() == .connected
        if linkUp, !readerEnded {
            await bestEffort("write End") { try await self.writeState(openClient, ConnectionStateValue.end) }
        }
        if linkUp {
            await bestEffort("unsubscribe from State") {
                try await self.unsubscribe(openClient, from: Characteristics.state)
            }
            await bestEffort("unsubscribe from Server2Client") {
                try await self.unsubscribe(openClient, from: Characteristics.serverToClient)
            }
        }
        openClient.close()
    }

    private func writeState(_ gattClient: GattClient, _ value: UInt8) async throws {
        try await gattClient.writeWithoutResponse(
            serviceUuid: serviceUuid,
            characteristicUuid: Characteristics.state,
            value: [value]
        )
    }

    private func subscribe(_ gattClient: GattClient, to characteristic: CBUUID) async throws {
        try await gattClient.enableNotifications(serviceUuid: serviceUuid, characteristicUuid: characteristic)
    }

    private func unsubscribe(_ gattClient: GattClient, from characteristic: CBUUID) async throws {
        try await gattClient.disableNotifications(serviceUuid: serviceUuid, characteristicUuid: characteristic)
    }

    private func isExpectedReader(_ candidate: GattClient) async throws -> Bool {
        let service = try await candidate.findService(serviceUuid)
        let found = Set(service.characteristics?.map(\.uuid) ?? [])
        if let missing = Characteristics.all.first(where: { !found.contains($0) }) {
            throw IsoTransportError("Reader service has no characteristic \(missing)")
        }
        let ident = try await candidate.read(serviceUuid: serviceUuid, characteristicUuid: Characteristics.ident)
        return ident == expectedIdent
    }

    private func isLostBeforeStart(_ error: Error) -> Bool {
        if let disconnected = error as? GattDisconnectedError { return disconnected.reason == .remoteDisconnected }
        if let failed = error as? GattOperationFailedError { return failed.operation == .connect }
        return false
    }

    private func bestEffort(_ step: String, _ action: () async throws -> Void) async {
        do {
            try await action()
        } catch {
            logger.warning("Could not \(step) while closing: \(error)")
        }
    }
}
