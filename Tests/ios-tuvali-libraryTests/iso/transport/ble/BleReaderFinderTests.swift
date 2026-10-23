import CoreBluetooth
import XCTest
@testable import ios_tuvali_library

/// Finding the reader that advertises the session service (clause 8.3.3.1.1.3), on AsyncBleCentral.
final class BleReaderFinderTests: XCTestCase {
    private let sessionUuid = CBUUID(string: "45efef74-2b2c-4837-a9a3-b0e1d05a6917")
    private var bluetooth: MockCoreBluetooth!
    private var finder: BleReaderFinder!

    override func setUp() {
        bluetooth = MockCoreBluetooth()
        finder = BleReaderFinder(central: bluetooth.central)
    }

    private func startFinding(excluding excluded: Set<UUID> = []) -> Task<GattPeripheral, Error> {
        let finder = finder!
        let sessionUuid = sessionUuid
        return Task { try await finder.findReader(serviceUuid: sessionUuid, excluding: excluded) }
    }

    private func waitForScan() async throws {
        try await eventually { self.bluetooth.onQueue { self.bluetooth.manager.scans.count == 1 } }
    }

    private func discover(_ peripheral: MockGattPeripheral) {
        bluetooth.deliver { self.bluetooth.central.discovered(peripheral) }
    }

    func testFindReaderScansWithOneFilterForTheSessionServiceUuid() async throws {
        let finding = startFinding()
        try await waitForScan()

        discover(MockGattPeripheral())
        _ = try await finding.value

        XCTAssertEqual(bluetooth.onQueue { bluetooth.manager.scans }, [[sessionUuid]])
    }

    func testFindReaderReturnsTheFirstReaderTheScanFinds() async throws {
        let finding = startFinding()
        try await waitForScan()
        let first = MockGattPeripheral()

        discover(first)
        discover(MockGattPeripheral())

        let found = try await finding.value
        XCTAssertEqual(found.identifier, first.identifier)
    }

    func testFindReaderSkipsExcludedReadersAndReturnsTheNextOne() async throws {
        let excluded = MockGattPeripheral()
        let next = MockGattPeripheral()
        let finding = startFinding(excluding: [excluded.identifier])
        try await waitForScan()

        discover(excluded)
        discover(next)

        let found = try await finding.value
        XCTAssertEqual(found.identifier, next.identifier)
    }

    func testFindReaderStopsScanningOnceItFindsAReader() async throws {
        let finding = startFinding()
        try await waitForScan()

        discover(MockGattPeripheral())
        _ = try await finding.value

        try await eventually { self.bluetooth.onQueue { self.bluetooth.manager.stopScanCount == 1 } }
    }

    func testFindReaderThrowsGattDisconnectedErrorWithoutScanningWhenBluetoothIsOff() async {
        bluetooth.onQueue { bluetooth.manager.state = .poweredOff }

        let failure = await errorThrown(by: startFinding())

        XCTAssertEqual(failure as? GattDisconnectedError, GattDisconnectedError(reason: .bluetoothTurnedOff))
        XCTAssertTrue(bluetooth.onQueue { bluetooth.manager.scans.isEmpty })
    }

    func testFindReaderThrowsGattDisconnectedErrorWhenBluetoothIsSwitchedOffWhileScanning() async throws {
        let finding = startFinding()
        try await waitForScan()

        bluetooth.deliver { self.bluetooth.central.stateChanged(.poweredOff) }

        let failure = await errorThrown(by: finding)
        XCTAssertEqual(failure as? GattDisconnectedError, GattDisconnectedError(reason: .bluetoothTurnedOff))
    }

    func testFindReaderThrowsBleScanFailedErrorWhenTheAppMayNotUseBluetooth() async {
        bluetooth.onQueue { bluetooth.manager.state = .unauthorized }

        let failure = await errorThrown(by: startFinding())

        XCTAssertTrue(failure is BleScanFailedError, "\(String(describing: failure))")
    }

    func testFindReaderStopsScanningWhenCancelled() async throws {
        let finding = startFinding()
        try await waitForScan()

        finding.cancel()

        let failure = await errorThrown(by: finding)
        XCTAssertTrue(failure is CancellationError, "\(String(describing: failure))")
        try await eventually { self.bluetooth.onQueue { self.bluetooth.manager.stopScanCount == 1 } }
    }
}
