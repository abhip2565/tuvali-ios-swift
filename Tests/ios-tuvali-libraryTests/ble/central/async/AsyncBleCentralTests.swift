import CoreBluetooth
import XCTest
@testable import ios_tuvali_library

/// The central: Bluetooth state, scanning by service, connecting, and links that go down.
final class AsyncBleCentralTests: XCTestCase {
    private var bluetooth: MockCoreBluetooth!
    private var peripheral: MockGattPeripheral!

    override func setUp() {
        bluetooth = MockCoreBluetooth()
        peripheral = MockGattPeripheral()
    }

    private func startConnecting() -> Task<AsyncGattClient, Error> {
        let central = bluetooth.central
        let peripheral = peripheral!
        return Task { try await central.connect(peripheral) }
    }

    private func connectRequestCount() -> Int {
        bluetooth.onQueue { bluetooth.manager.connectRequests.count }
    }

    // MARK: connecting

    func testConnectCompletesAndReportsConnectedWhenIosReportsASuccessfulConnection() async throws {
        let connection = startConnecting()
        try await eventually { self.connectRequestCount() == 1 }

        bluetooth.deliver { self.bluetooth.central.connected(self.peripheral) }

        let client = try await connection.value
        XCTAssertEqual(bluetooth.onQueue { client.connectionState }, .connected)
    }

    func testConnectThrowsGattOperationFailedErrorWhenIosReportsAFailedConnection() async throws {
        let connection = startConnecting()
        try await eventually { self.connectRequestCount() == 1 }

        bluetooth.deliver { self.bluetooth.central.failedToConnect(self.peripheral, error: nil) }

        let error = await errorThrown(by: connection)
        XCTAssertEqual((error as? GattOperationFailedError)?.operation, .connect)
    }

    func testConnectThrowsGattOperationFailedErrorWhenTheLinkDropsBeforeItIsUp() async throws {
        let connection = startConnecting()
        try await eventually { self.connectRequestCount() == 1 }

        bluetooth.deliver { self.bluetooth.central.disconnected(self.peripheral, error: nil) }

        let error = await errorThrown(by: connection)
        XCTAssertEqual((error as? GattOperationFailedError)?.operation, .connect)
    }

    func testConnectThrowsGattOperationTimeoutErrorAndCancelsTheAttemptWhenIosNeverReportsTheConnection() async throws {
        let connection = startConnecting()

        let error = await errorThrown(by: connection)

        XCTAssertEqual((error as? GattOperationTimeoutError)?.operation, .connect)
        XCTAssertEqual(bluetooth.onQueue { bluetooth.manager.cancelledConnections }, [peripheral.identifier])
    }

    func testConnectThrowsGattDisconnectedErrorWhenBluetoothIsOff() async throws {
        bluetooth.onQueue { bluetooth.manager.state = .poweredOff }

        let error = await errorThrown(by: startConnecting())

        XCTAssertEqual(error as? GattDisconnectedError, GattDisconnectedError(reason: .bluetoothTurnedOff))
        XCTAssertEqual(connectRequestCount(), 0)
    }

    func testConnectThrowsGattDisconnectedErrorWhenBluetoothIsSwitchedOffWhileConnecting() async throws {
        let connection = startConnecting()
        try await eventually { self.connectRequestCount() == 1 }

        bluetooth.deliver { self.bluetooth.central.stateChanged(.poweredOff) }

        let error = await errorThrown(by: connection)
        XCTAssertEqual(error as? GattDisconnectedError, GattDisconnectedError(reason: .bluetoothTurnedOff))
    }

    func testConnectThrowsGattOperationFailedErrorWhenAnotherConnectionIsInProgress() async throws {
        _ = startConnecting()
        try await eventually { self.connectRequestCount() == 1 }

        let error = await errorThrown(by: startConnecting())

        XCTAssertEqual((error as? GattOperationFailedError)?.operation, .connect)
    }

    // MARK: links going down

    func testConnectionStateBecomesLostWithRemoteDisconnectedWhenTheLinkDropsWhileIdle() async throws {
        let client = try await bluetooth.connectedClient(to: peripheral)

        bluetooth.deliver { self.bluetooth.central.disconnected(self.peripheral, error: nil) }

        XCTAssertEqual(bluetooth.onQueue { client.connectionState }, .lost(.remoteDisconnected))
    }

    func testConnectionStateBecomesLostWithBluetoothTurnedOffWhenBluetoothIsSwitchedOffWhileIdle() async throws {
        let client = try await bluetooth.connectedClient(to: peripheral)

        bluetooth.deliver { self.bluetooth.central.stateChanged(.poweredOff) }

        XCTAssertEqual(bluetooth.onQueue { client.connectionState }, .lost(.bluetoothTurnedOff))
    }

    func testConnectionStateBecomesLostWithBluetoothTurnedOffWhenBluetoothResets() async throws {
        let client = try await bluetooth.connectedClient(to: peripheral)

        bluetooth.deliver { self.bluetooth.central.stateChanged(.resetting) }

        XCTAssertEqual(bluetooth.onQueue { client.connectionState }, .lost(.bluetoothTurnedOff))
    }

    func testConnectionStateBecomesLostWithBluetoothTurnedOffWhenTheAppLosesBluetoothPermission() async throws {
        let client = try await bluetooth.connectedClient(to: peripheral)

        bluetooth.deliver { self.bluetooth.central.stateChanged(.unauthorized) }

        XCTAssertEqual(bluetooth.onQueue { client.connectionState }, .lost(.bluetoothTurnedOff))
    }

    func testConnectThrowsGattDisconnectedErrorWhenBluetoothResetsWhileConnecting() async throws {
        let connection = startConnecting()
        try await eventually { self.connectRequestCount() == 1 }

        bluetooth.deliver { self.bluetooth.central.stateChanged(.resetting) }

        let error = await errorThrown(by: connection)
        XCTAssertEqual(error as? GattDisconnectedError, GattDisconnectedError(reason: .bluetoothTurnedOff))
    }

    func testALinkLostToBluetoothTurningOffStopsReceivingThatPeripheralsEvents() async throws {
        _ = try await bluetooth.connectedClient(to: peripheral)

        bluetooth.deliver { self.bluetooth.central.stateChanged(.poweredOff) }

        XCTAssertFalse(bluetooth.onQueue { bluetooth.manager.peripheralsWithEvents.contains(peripheral.identifier) })
    }

    func testCloseCancelsTheConnectionAndReportsDisconnected() async throws {
        let client = try await bluetooth.connectedClient(to: peripheral)

        client.close()

        XCTAssertEqual(bluetooth.onQueue { client.connectionState }, .disconnected)
        XCTAssertEqual(bluetooth.onQueue { bluetooth.manager.cancelledConnections }, [peripheral.identifier])
    }

    func testOperationsThrowGattDisconnectedErrorAfterClose() async throws {
        let client = try await bluetooth.connectedClient(to: peripheral)
        bluetooth.onQueue { peripheral.markDiscovered() }

        client.close()
        let read = Task { try await client.read(MockGattPeripheral.readUuid) }

        let error = await errorThrown(by: read)
        XCTAssertEqual(error as? GattDisconnectedError, GattDisconnectedError(reason: nil))
        XCTAssertTrue(bluetooth.onQueue { peripheral.readRequests.isEmpty })
    }

    // MARK: scanning

    func testScanAsksIosToScanForTheServiceAndYieldsEachPeripheralFound() async throws {
        let scan = bluetooth.central.scan(for: MockGattPeripheral.serviceUuid)
        let found = Task { () -> [UUID] in
            var identifiers: [UUID] = []
            for try await peripheral in scan {
                identifiers.append(peripheral.identifier)
                if identifiers.count == 2 { break }
            }
            return identifiers
        }
        try await eventually { self.bluetooth.onQueue { self.bluetooth.manager.scans.count == 1 } }
        let other = MockGattPeripheral()

        bluetooth.deliver { self.bluetooth.central.discovered(self.peripheral) }
        bluetooth.deliver { self.bluetooth.central.discovered(other) }

        let identifiers = try await found.value
        XCTAssertEqual(identifiers, [peripheral.identifier, other.identifier])
        XCTAssertEqual(bluetooth.onQueue { bluetooth.manager.scans }, [[MockGattPeripheral.serviceUuid]])
    }

    func testScanWaitsForBluetoothToPowerOnBeforeScanning() async throws {
        bluetooth.onQueue { bluetooth.manager.state = .unknown }
        let scan = bluetooth.central.scan(for: MockGattPeripheral.serviceUuid)
        let firstFound = Task { () -> UUID? in
            for try await peripheral in scan { return peripheral.identifier }
            return nil
        }

        try await Task.sleep(nanoseconds: 50_000_000)
        let scansBeforePowerOn = bluetooth.onQueue { bluetooth.manager.scans.count }
        bluetooth.deliver {
            self.bluetooth.manager.state = .poweredOn
            self.bluetooth.central.stateChanged(.poweredOn)
        }
        try await eventually { self.bluetooth.onQueue { self.bluetooth.manager.scans.count == 1 } }
        bluetooth.deliver { self.bluetooth.central.discovered(self.peripheral) }

        XCTAssertEqual(scansBeforePowerOn, 0)
        let identifier = try await firstFound.value
        XCTAssertEqual(identifier, peripheral.identifier)
    }

    func testScanThrowsGattDisconnectedErrorWhenBluetoothIsSwitchedOffWhileScanning() async throws {
        let scan = bluetooth.central.scan(for: MockGattPeripheral.serviceUuid)
        let scanning = Task { for try await _ in scan {} }
        try await eventually { self.bluetooth.onQueue { self.bluetooth.manager.scans.count == 1 } }

        bluetooth.deliver { self.bluetooth.central.stateChanged(.poweredOff) }

        let error = await errorThrown(by: scanning)
        XCTAssertEqual(error as? GattDisconnectedError, GattDisconnectedError(reason: .bluetoothTurnedOff))
    }

    func testScanThrowsBleScanFailedErrorWhenTheAppMayNotUseBluetooth() async throws {
        bluetooth.onQueue { bluetooth.manager.state = .unauthorized }
        let scan = bluetooth.central.scan(for: MockGattPeripheral.serviceUuid)

        let error = await errorThrown(by: Task { for try await _ in scan {} })

        XCTAssertTrue(error is BleScanFailedError, "\(String(describing: error))")
        XCTAssertEqual(bluetooth.onQueue { bluetooth.manager.scans.count }, 0)
    }

    func testStopScanStopsScanningAndEndsTheStreamNormally() async throws {
        let scan = bluetooth.central.scan(for: MockGattPeripheral.serviceUuid)
        let scanning = Task { () -> Int in
            var found = 0
            for try await _ in scan { found += 1 }
            return found
        }
        try await eventually { self.bluetooth.onQueue { self.bluetooth.manager.scans.count == 1 } }

        bluetooth.central.stopScan()

        let found = try await scanning.value
        XCTAssertEqual(found, 0)
        XCTAssertEqual(bluetooth.onQueue { bluetooth.manager.stopScanCount }, 1)
    }

    func testScanStopsWhenTheListeningTaskIsCancelled() async throws {
        let scan = bluetooth.central.scan(for: MockGattPeripheral.serviceUuid)
        let scanning = Task { for try await _ in scan {} }
        try await eventually { self.bluetooth.onQueue { self.bluetooth.manager.scans.count == 1 } }

        scanning.cancel()

        try await eventually { self.bluetooth.onQueue { self.bluetooth.manager.stopScanCount == 1 } }
    }
}
