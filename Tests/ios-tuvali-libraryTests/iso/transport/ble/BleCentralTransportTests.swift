import CoreBluetooth
import XCTest
@testable import ios_tuvali_library

/// The ISO 18013-5 BLE transport with the mdoc as GATT client: clauses 8.3.3.1.1.3 to 8.3.3.1.1.8.
final class BleCentralTransportTests: XCTestCase {
    private let sessionUuid = CBUUID(string: "45efef74-2b2c-4837-a9a3-b0e1d05a6917")
    private let expectedIdent = "ec2667104dccaf62fc6976cc75f1abdb".hexToBytes()
    private let wrongIdent = [UInt8](repeating: 0, count: 16)
    private var finder: ScriptedReaderFinder!

    override func setUp() {
        finder = ScriptedReaderFinder()
    }

    private func transport(maxConnectAttempts: Int = 3) -> BleCentralTransport {
        let finder = finder!
        return BleCentralTransport(
            serviceUuid: sessionUuid,
            expectedIdent: expectedIdent,
            readerFinder: finder,
            connect: { peripheral in try finder.connect(peripheral) },
            maxConnectAttempts: maxConnectAttempts
        )
    }

    @discardableResult
    private func reader(
        ident: [UInt8]? = nil,
        partBytes: Int = 182,
        missingCharacteristic: CBUUID? = nil
    ) -> MockIsoReader {
        let reader = MockIsoReader(
            serviceUuid: sessionUuid,
            ident: ident ?? expectedIdent,
            partBytes: partBytes,
            missingCharacteristic: missingCharacteristic
        )
        finder.add(reader)
        return reader
    }

    private func openTransport() async throws -> BleCentralTransport {
        let transport = transport()
        try await transport.open()
        return transport
    }

    private func error(of action: () async throws -> Void) async -> Error? {
        do {
            try await action()
            return nil
        } catch {
            return error
        }
    }

    // MARK: opening the connection

    func testOpenChecksIdentSubscribesToStateAndServer2ClientThenWritesStart() async throws {
        let reader = reader()

        try await transport().open()

        XCTAssertEqual(reader.events, ["connect", "read ident", "subscribe 05", "subscribe 07", "state 01"])
    }

    func testOpenWritesStartEvenWhenTheReaderSentItsFirstMessageEarly() async throws {
        let reader = reader()
        // an eager reader notifies its SessionEstablishment before the wallet has written Start
        reader.sendMessage("a1".hexToBytes())

        let transport = try await openTransport()

        let event = try await transport.receive()
        XCTAssertTrue(reader.events.contains("state 01"))
        XCTAssertEqual(event, .message("a1".hexToBytes()))
    }

    func testOpenLeavesAReaderWhoseIdentDoesNotMatchAndConnectsToTheNextOne() async throws {
        // a different reader nearby that also advertises the session UUID
        let wrongReader = reader(ident: wrongIdent)
        let rightReader = reader()

        try await transport().open()

        XCTAssertEqual(wrongReader.events, ["connect", "read ident", "close"])
        XCTAssertTrue(rightReader.events.contains("state 01"))
        XCTAssertEqual(finder.scanRequests.last, [wrongReader.peripheral.identifier])
    }

    func testOpenThrowsIsoTransportErrorAndClosesTheConnectionWhenATable12CharacteristicIsMissing() async {
        let reader = reader(missingCharacteristic: readerIdent)

        let failure = await error { try await transport().open() }

        XCTAssertTrue(failure is IsoTransportError, "\(String(describing: failure))")
        XCTAssertTrue(reader.wasClosed)
    }

    func testOpenConnectsAgainWhenTheLinkDropsBeforeStart() async throws {
        let firstTry = reader()
        firstTry.failOnSubscribe = GattDisconnectedError(reason: .remoteDisconnected)
        let secondTry = reader()

        try await transport().open()

        XCTAssertTrue(firstTry.wasClosed)
        XCTAssertFalse(firstTry.events.contains("state 01"))
        XCTAssertTrue(secondTry.events.contains("state 01"))
    }

    func testOpenThrowsGattDisconnectedErrorWhenTheLinkKeepsDroppingBeforeStart() async {
        for _ in 1...2 { reader().failOnSubscribe = GattDisconnectedError(reason: .remoteDisconnected) }

        let failure = await error { try await transport(maxConnectAttempts: 2).open() }

        XCTAssertTrue(failure is GattDisconnectedError, "\(String(describing: failure))")
    }

    func testOpenConnectsAgainWhenTheFirstConnectionAttemptFails() async throws {
        reader().failOnConnect = GattOperationFailedError(operation: .connect, detail: "iOS could not connect")
        let secondTry = reader()

        try await transport().open()

        XCTAssertTrue(secondTry.events.contains("state 01"))
    }

    func testOpenDoesNotCountReadersWithAWrongIdentAsLostConnections() async throws {
        // two wrong readers nearby, then one link drop, with room for two connection attempts
        reader(ident: wrongIdent)
        reader(ident: wrongIdent)
        reader().failOnSubscribe = GattDisconnectedError(reason: .remoteDisconnected)
        let finalTry = reader()

        try await transport(maxConnectAttempts: 2).open()

        XCTAssertTrue(finalTry.events.contains("state 01"))
    }

    func testOpenDoesNotRetryAfterAGattOperationTimesOut() async {
        let reader = reader()
        reader.failOnIdentRead = GattOperationTimeoutError(operation: .readCharacteristic, timeout: 5)
        self.reader()

        let failure = await error { try await transport().open() }

        XCTAssertTrue(failure is GattOperationTimeoutError, "\(String(describing: failure))")
        XCTAssertTrue(reader.wasClosed)
        XCTAssertEqual(finder.scanRequests.count, 1)
    }

    func testOpenDoesNotRetryWhenBluetoothIsSwitchedOffBeforeStart() async {
        reader().failOnSubscribe = GattDisconnectedError(reason: .bluetoothTurnedOff)
        reader()

        let failure = await error { try await transport().open() }

        XCTAssertEqual(failure as? GattDisconnectedError, GattDisconnectedError(reason: .bluetoothTurnedOff))
        XCTAssertEqual(finder.scanRequests.count, 1)
    }

    // MARK: sending

    func testSendWritesTheMessageToClient2ServerInPartsOfMtuMinus3Bytes() async throws {
        // the smallest MTU (23): parts of 20 bytes, 19 of them message
        let reader = reader(partBytes: 20)
        let transport = try await openTransport()
        let message = (0..<50).map { UInt8($0) }

        try await transport.send(message)

        XCTAssertEqual(reader.clientToServerParts.map(\.count), [20, 20, 13])
        XCTAssertEqual(reader.receivedMessages(), [message])
    }

    func testSendNeverWritesAPartLargerThanTheLargestAttributeValue() async throws {
        // an attribute value holds at most 512 bytes, whatever write length iOS reports
        let reader = reader(partBytes: 600)
        let transport = try await openTransport()

        try await transport.send([UInt8](repeating: 1, count: 2000))

        XCTAssertEqual(reader.clientToServerParts.map(\.count).max(), 512)
    }

    func testSendThrowsIsoTransportStateErrorBeforeOpen() async {
        let transport = transport()

        let failure = await error { try await transport.send([1]) }

        XCTAssertTrue(failure is IsoTransportStateError, "\(String(describing: failure))")
    }

    func testSendThrowsGattDisconnectedErrorAfterTheLinkDropsAndDoesNotReconnect() async throws {
        let reader = reader()
        let transport = try await openTransport()
        reader.dropLink()

        let failure = await error { try await transport.send([1]) }

        XCTAssertTrue(failure is GattDisconnectedError, "\(String(describing: failure))")
        XCTAssertEqual(finder.scanRequests.count, 1)
    }

    // MARK: receiving

    func testReceiveReturnsAWholeMessageRebuiltFromTheReadersParts() async throws {
        let reader = reader(partBytes: 20)
        let transport = try await openTransport()
        let message = (0..<60).map { UInt8(truncatingIfNeeded: $0 * 7) }
        reader.sendMessage(message)

        let event = try await transport.receive()

        XCTAssertEqual(event, .message(message))
    }

    func testReceiveReturnsEndedWhenTheReaderWritesEndToState() async throws {
        let reader = reader()
        let transport = try await openTransport()
        reader.sendState(0x02)

        let event = try await transport.receive()

        XCTAssertEqual(event, .ended)
    }

    func testReceiveReturnsEndedWhenTheReaderWritesEndHalfwayThroughAMessage() async throws {
        let reader = reader()
        let transport = try await openTransport()
        // the first part of a message (more parts announced), then End
        reader.sendRawPart("01a1a2".hexToBytes())
        reader.sendState(0x02)

        let event = try await transport.receive()

        XCTAssertEqual(event, .ended)
    }

    func testReceiveIgnoresStateValuesOtherThanEnd() async throws {
        let reader = reader()
        let transport = try await openTransport()
        reader.sendState(0x01)
        reader.sendMessage("a1".hexToBytes())

        let event = try await transport.receive()

        XCTAssertEqual(event, .message("a1".hexToBytes()))
    }

    func testReceiveThrowsGattDisconnectedErrorWhenTheLinkDropsWhileWaiting() async throws {
        let reader = reader()
        let transport = try await openTransport()
        let receiving = Task { try await transport.receive() }

        reader.dropLink()

        let failure = await errorThrown(by: receiving)
        XCTAssertTrue(failure is GattDisconnectedError, "\(String(describing: failure))")
    }

    func testReceiveThrowsCancellationErrorWhenTheWaitingTaskIsCancelled() async throws {
        // a cancel is not a lost link: the presenter reports the two differently
        reader()
        let transport = try await openTransport()
        let receiving = Task { try await transport.receive() }
        try await Task.sleep(nanoseconds: 20_000_000)

        receiving.cancel()

        let failure = await errorThrown(by: receiving)
        XCTAssertTrue(failure is CancellationError, "\(String(describing: failure))")
    }

    func testReceiveThrowsIsoTransportErrorForAPartWithAnUnknownHeader() async throws {
        let reader = reader()
        let transport = try await openTransport()
        reader.sendRawPart("03a1".hexToBytes())

        let failure = await error { _ = try await transport.receive() }

        XCTAssertTrue(failure is IsoTransportError, "\(String(describing: failure))")
    }

    func testSendThrowsIsoTransportStateErrorAfterTheReaderEndedTheSession() async throws {
        let reader = reader()
        let transport = try await openTransport()
        reader.sendState(0x02)
        _ = try await transport.receive()

        let failure = await error { try await transport.send([1]) }

        XCTAssertTrue(failure is IsoTransportStateError, "\(String(describing: failure))")
    }

    func testReceiveIgnoresNotificationsFromOtherCharacteristics() async throws {
        // on iOS a late read answer arrives like a notification; only State and Server2Client count
        let reader = reader()
        let transport = try await openTransport()
        reader.sendNotification(on: readerIdent, [0x00, 0xaa])
        reader.sendMessage("a1".hexToBytes())

        let event = try await transport.receive()

        XCTAssertEqual(event, .message("a1".hexToBytes()))
    }

    // MARK: closing

    func testCloseWritesEndUnsubscribesFromStateAndServer2ClientThenDisconnects() async throws {
        let reader = reader()
        let transport = try await openTransport()

        await transport.close()

        XCTAssertEqual(Array(reader.events.suffix(4)), ["state 02", "unsubscribe 05", "unsubscribe 07", "close"])
    }

    func testCloseDoesNotWriteEndWhenTheReaderAlreadyEndedButStillUnsubscribesAndDisconnects() async throws {
        let reader = reader()
        let transport = try await openTransport()
        reader.sendState(0x02)
        _ = try await transport.receive()

        await transport.close()

        XCTAssertEqual(Array(reader.events.suffix(3)), ["unsubscribe 05", "unsubscribe 07", "close"])
        XCTAssertFalse(reader.events.contains("state 02"))
    }

    func testCloseStillDisconnectsWhenTheLinkIsAlreadyGone() async throws {
        let reader = reader()
        let transport = try await openTransport()
        reader.dropLink()

        await transport.close()

        XCTAssertTrue(reader.wasClosed)
    }

    func testCloseDoesNothingWhenOpenNeverConnected() async {
        let transport = transport()

        await transport.close()

        XCTAssertTrue(finder.scanRequests.isEmpty)
    }
}
