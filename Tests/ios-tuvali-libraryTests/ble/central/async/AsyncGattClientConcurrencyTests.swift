import CoreBluetooth
import XCTest
@testable import ios_tuvali_library

/// One GATT operation at a time: queueing, timeouts, late answers, link loss and cancellation.
final class AsyncGattClientConcurrencyTests: XCTestCase {
    private var bluetooth: MockCoreBluetooth!
    private var peripheral: MockGattPeripheral!
    private var client: AsyncGattClient!

    override func setUp() async throws {
        bluetooth = MockCoreBluetooth()
        peripheral = MockGattPeripheral()
        client = try await bluetooth.connectedClient(to: peripheral)
        bluetooth.onQueue { peripheral.markDiscovered() }
    }

    private func startRead(_ characteristicUuid: CBUUID) -> Task<[UInt8], Error> {
        let client = client!
        return Task { try await client.read(characteristicUuid) }
    }

    private func deliverValue(_ value: [UInt8], for characteristicUuid: CBUUID) {
        let characteristic = peripheral.characteristic(characteristicUuid)
        bluetooth.deliver {
            characteristic.value = Data(value)
            self.client.updatedValue(for: characteristic, error: nil)
        }
    }

    private func readRequestCount() -> Int {
        bluetooth.onQueue { peripheral.readRequests.count }
    }

    func testASecondOperationDoesNotReachIosUntilTheFirstOneCompletes() async throws {
        let firstRead = startRead(MockGattPeripheral.readUuid)
        try await eventually { self.readRequestCount() == 1 }
        let secondRead = startRead(MockGattPeripheral.notifyUuid)

        try await Task.sleep(nanoseconds: 50_000_000)
        let requestsWhileFirstIsPending = readRequestCount()
        // checked before waiting on the reads: if both had started, the first would never finish
        XCTAssertEqual(requestsWhileFirstIsPending, 1)
        guard requestsWhileFirstIsPending == 1 else { return }
        deliverValue([0x01], for: MockGattPeripheral.readUuid)
        _ = try await firstRead.value
        try await eventually { self.readRequestCount() == 2 }
        deliverValue([0x02], for: MockGattPeripheral.notifyUuid)

        let secondValue = try await secondRead.value
        XCTAssertEqual(secondValue, [0x02])
    }

    func testAValueForADifferentCharacteristicDoesNotCompleteThePendingRead() async throws {
        let read = startRead(MockGattPeripheral.readUuid)
        try await eventually { self.readRequestCount() == 1 }

        deliverValue([0x09], for: MockGattPeripheral.notifyUuid)
        try await Task.sleep(nanoseconds: 50_000_000)
        deliverValue([0x01], for: MockGattPeripheral.readUuid)

        let value = try await read.value
        XCTAssertEqual(value, [0x01])
    }

    func testAnOperationThatTimesOutThrowsGattOperationTimeoutError() async throws {
        // iOS never answers the read
        let read = startRead(MockGattPeripheral.readUuid)

        let error = await errorThrown(by: read)

        XCTAssertEqual((error as? GattOperationTimeoutError)?.operation, .readCharacteristic)
    }

    func testAnAnswerArrivingAfterItsOperationTimedOutDoesNotDisturbTheNextOperation() async throws {
        _ = await errorThrown(by: startRead(MockGattPeripheral.readUuid))
        let nextRead = startRead(MockGattPeripheral.notifyUuid)
        try await eventually { self.readRequestCount() == 2 }

        // the timed-out read's answer arrives late, then the next read's own answer
        deliverValue([0x0a], for: MockGattPeripheral.readUuid)
        deliverValue([0x02], for: MockGattPeripheral.notifyUuid)

        let value = try await nextRead.value
        XCTAssertEqual(value, [0x02])
    }

    func testALateResultForTheSameCharacteristicCompletesTheNextReadOfThatCharacteristic() async throws {
        // CoreBluetooth answers carry no request id: this is why a timeout ends the session
        _ = await errorThrown(by: startRead(MockGattPeripheral.readUuid))
        let nextRead = startRead(MockGattPeripheral.readUuid)
        try await eventually { self.readRequestCount() == 2 }

        deliverValue([0x0a], for: MockGattPeripheral.readUuid)

        let value = try await nextRead.value
        XCTAssertEqual(value, [0x0a])
    }

    func testAPendingOperationThrowsGattDisconnectedErrorWhenTheLinkDrops() async throws {
        let read = startRead(MockGattPeripheral.readUuid)
        try await eventually { self.readRequestCount() == 1 }

        bluetooth.deliver { self.bluetooth.central.disconnected(self.peripheral, error: nil) }

        let error = await errorThrown(by: read)
        XCTAssertEqual(error as? GattDisconnectedError, GattDisconnectedError(reason: .remoteDisconnected))
    }

    func testAPendingOperationThrowsGattDisconnectedErrorWhenBluetoothIsSwitchedOff() async throws {
        let read = startRead(MockGattPeripheral.readUuid)
        try await eventually { self.readRequestCount() == 1 }

        bluetooth.deliver { self.bluetooth.central.stateChanged(.poweredOff) }

        let error = await errorThrown(by: read)
        XCTAssertEqual(error as? GattDisconnectedError, GattDisconnectedError(reason: .bluetoothTurnedOff))
    }

    func testOperationsQueuedBehindADroppedLinkAlsoThrowGattDisconnectedError() async throws {
        let firstRead = startRead(MockGattPeripheral.readUuid)
        try await eventually { self.readRequestCount() == 1 }
        let queuedRead = startRead(MockGattPeripheral.notifyUuid)
        try await Task.sleep(nanoseconds: 20_000_000)

        bluetooth.deliver { self.bluetooth.central.disconnected(self.peripheral, error: nil) }

        _ = await errorThrown(by: firstRead)
        let error = await errorThrown(by: queuedRead)
        XCTAssertEqual(error as? GattDisconnectedError, GattDisconnectedError(reason: .remoteDisconnected))
        XCTAssertEqual(readRequestCount(), 1)
    }

    func testACancelledOperationLetsTheNextOperationReachIos() async throws {
        let cancelledRead = startRead(MockGattPeripheral.readUuid)
        try await eventually { self.readRequestCount() == 1 }

        cancelledRead.cancel()
        _ = await errorThrown(by: cancelledRead)
        let nextRead = startRead(MockGattPeripheral.notifyUuid)
        try await eventually { self.readRequestCount() == 2 }
        deliverValue([0x02], for: MockGattPeripheral.notifyUuid)

        let value = try await nextRead.value
        XCTAssertEqual(value, [0x02])
    }

    func testAPendingOperationThrowsGattDisconnectedErrorWhenTheClientIsClosed() async throws {
        let read = startRead(MockGattPeripheral.readUuid)
        try await eventually { self.readRequestCount() == 1 }

        client.close()

        let error = await errorThrown(by: read)
        XCTAssertEqual(error as? GattDisconnectedError, GattDisconnectedError(reason: nil))
    }
}
