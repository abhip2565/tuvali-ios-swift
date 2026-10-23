import CoreBluetooth
import XCTest
@testable import ios_tuvali_library

/// Subscribing, unsubscribing and the notification stream. On iOS, setNotifyValue writes the
/// CCCD itself (0x0001 or 0x0002, as the characteristic allows) and reports when it is done.
final class AsyncGattClientNotificationsTests: XCTestCase {
    private var bluetooth: MockCoreBluetooth!
    private var peripheral: MockGattPeripheral!
    private var client: AsyncGattClient!
    private let attError = NSError(domain: CBATTErrorDomain, code: CBATTError.Code.unlikelyError.rawValue)

    override func setUp() async throws {
        bluetooth = MockCoreBluetooth()
        peripheral = MockGattPeripheral()
        client = try await bluetooth.connectedClient(to: peripheral)
        bluetooth.onQueue { peripheral.markDiscovered() }
    }

    private func startEnabling(_ characteristicUuid: CBUUID) -> Task<Void, Error> {
        let client = client!
        return Task {
            try await client.enableNotifications(characteristicUuid)
        }
    }

    private func startDisabling(_ characteristicUuid: CBUUID) -> Task<Void, Error> {
        let client = client!
        return Task {
            try await client.disableNotifications(characteristicUuid)
        }
    }

    private func confirmNotificationState(of characteristicUuid: CBUUID, error: Error? = nil) {
        let characteristic = peripheral.characteristic(characteristicUuid)
        bluetooth.deliver { self.client.updatedNotificationState(for: characteristic, error: error) }
    }

    private func notify(_ value: [UInt8], on characteristicUuid: CBUUID) {
        let characteristic = peripheral.characteristic(characteristicUuid)
        bluetooth.deliver {
            characteristic.value = Data(value)
            self.client.updatedValue(for: characteristic, error: nil)
        }
    }

    private func notifyRequests() -> [(characteristic: CBUUID, enabled: Bool)] {
        bluetooth.onQueue { peripheral.notifyRequests }
    }

    // MARK: subscribing

    func testEnableNotificationsAsksIosToSubscribeToANotifyCharacteristic() async throws {
        let enabling = startEnabling(MockGattPeripheral.notifyUuid)
        try await eventually { self.notifyRequests().count == 1 }

        confirmNotificationState(of: MockGattPeripheral.notifyUuid)
        try await enabling.value

        XCTAssertEqual(notifyRequests().map(\.characteristic), [MockGattPeripheral.notifyUuid])
        XCTAssertEqual(notifyRequests().map(\.enabled), [true])
    }

    func testEnableNotificationsAsksIosToSubscribeToAnIndicateOnlyCharacteristic() async throws {
        let enabling = startEnabling(MockGattPeripheral.indicateUuid)
        try await eventually { self.notifyRequests().count == 1 }

        confirmNotificationState(of: MockGattPeripheral.indicateUuid)
        try await enabling.value

        XCTAssertEqual(notifyRequests().map(\.characteristic), [MockGattPeripheral.indicateUuid])
    }

    func testEnableNotificationsWaitsForIosToConfirmTheSubscriptionBeforeReturning() async throws {
        let enabling = startEnabling(MockGattPeripheral.notifyUuid)
        try await eventually { self.notifyRequests().count == 1 }

        // iOS never confirms
        let error = await errorThrown(by: enabling)

        XCTAssertEqual((error as? GattOperationTimeoutError)?.operation, .enableNotifications)
    }

    func testEnableNotificationsThrowsGattOperationFailedErrorWhenIosReportsASubscriptionError() async throws {
        let enabling = startEnabling(MockGattPeripheral.notifyUuid)
        try await eventually { self.notifyRequests().count == 1 }

        confirmNotificationState(of: MockGattPeripheral.notifyUuid, error: attError)

        let error = await errorThrown(by: enabling)
        XCTAssertEqual((error as? GattOperationFailedError)?.operation, .enableNotifications)
    }

    func testEnableNotificationsThrowsGattOperationFailedErrorWhenTheCharacteristicCannotNotify() async throws {
        let enabling = startEnabling(MockGattPeripheral.readUuid)

        let error = await errorThrown(by: enabling)

        XCTAssertEqual((error as? GattOperationFailedError)?.operation, .enableNotifications)
        XCTAssertTrue(notifyRequests().isEmpty)
    }

    func testEnableNotificationsThrowsGattAttributeNotFoundErrorWhenTheCharacteristicDoesNotExist() async throws {
        let missing = CBUUID(string: "0000a0ff-0000-1000-8000-00805f9b34fb")
        let client = client!

        let enabling = Task { try await client.enableNotifications(missing) }

        let error = await errorThrown(by: enabling)
        XCTAssertTrue(error is GattAttributeNotFoundError, "\(String(describing: error))")
    }

    // MARK: the notification stream

    func testNotificationsDeliversEachNotifiedValueInTheOrderIosDeliveredThem() async throws {
        notify([0x01], on: MockGattPeripheral.notifyUuid)
        notify([0x02], on: MockGattPeripheral.indicateUuid)
        notify([0x03], on: MockGattPeripheral.notifyUuid)
        client.close()

        var received: [GattNotification] = []
        for try await notification in client.notifications { received.append(notification) }

        XCTAssertEqual(received, [
            GattNotification(characteristicUuid: MockGattPeripheral.notifyUuid, value: [0x01]),
            GattNotification(characteristicUuid: MockGattPeripheral.indicateUuid, value: [0x02]),
            GattNotification(characteristicUuid: MockGattPeripheral.notifyUuid, value: [0x03]),
        ])
    }

    func testNotificationsKeepsTheValueAsItWasWhenNotifiedEvenIfTheCharacteristicChangesLater() async throws {
        notify([0x01], on: MockGattPeripheral.notifyUuid)
        bluetooth.onQueue { peripheral.notifyCharacteristic.value = Data([0xff]) }
        client.close()

        var received: [[UInt8]] = []
        for try await notification in client.notifications { received.append(notification.value) }

        XCTAssertEqual(received, [[0x01]])
    }

    func testAValueForTheCharacteristicBeingReadCompletesTheReadInsteadOfBecomingANotification() async throws {
        // CoreBluetooth reports read results and notifications through the same callback
        let client = client!
        let read = Task { try await client.read(MockGattPeripheral.readUuid) }
        try await eventually { self.bluetooth.onQueue { self.peripheral.readRequests.count == 1 } }

        notify([0x07], on: MockGattPeripheral.readUuid)
        let value = try await read.value
        client.close()
        var notified: [GattNotification] = []
        for try await notification in client.notifications { notified.append(notification) }

        XCTAssertEqual(value, [0x07])
        XCTAssertTrue(notified.isEmpty)
    }

    // MARK: unsubscribing

    func testDisableNotificationsAsksIosToUnsubscribeAndWaitsForItToConfirm() async throws {
        let disabling = startDisabling(MockGattPeripheral.notifyUuid)
        try await eventually { self.notifyRequests().count == 1 }

        confirmNotificationState(of: MockGattPeripheral.notifyUuid)
        try await disabling.value

        XCTAssertEqual(notifyRequests().map(\.characteristic), [MockGattPeripheral.notifyUuid])
        XCTAssertEqual(notifyRequests().map(\.enabled), [false])
    }

    func testDisableNotificationsThrowsGattOperationFailedErrorWhenIosReportsAnError() async throws {
        let disabling = startDisabling(MockGattPeripheral.notifyUuid)
        try await eventually { self.notifyRequests().count == 1 }

        confirmNotificationState(of: MockGattPeripheral.notifyUuid, error: attError)

        let error = await errorThrown(by: disabling)
        XCTAssertEqual((error as? GattOperationFailedError)?.operation, .disableNotifications)
    }

    // MARK: the end of the stream

    func testNotificationsDeliversValuesReceivedBeforeALinkDropThenThrowsGattDisconnectedError() async throws {
        notify([0x01], on: MockGattPeripheral.notifyUuid)
        bluetooth.deliver { self.bluetooth.central.disconnected(self.peripheral, error: nil) }

        var received: [[UInt8]] = []
        var streamError: Error?
        do {
            for try await notification in client.notifications { received.append(notification.value) }
        } catch {
            streamError = error
        }

        XCTAssertEqual(received, [[0x01]])
        XCTAssertEqual(streamError as? GattDisconnectedError, GattDisconnectedError(reason: .remoteDisconnected))
    }

    func testNotificationsEndsNormallyAfterClose() async throws {
        client.close()

        var count = 0
        for try await _ in client.notifications { count += 1 }

        XCTAssertEqual(count, 0)
    }
}
