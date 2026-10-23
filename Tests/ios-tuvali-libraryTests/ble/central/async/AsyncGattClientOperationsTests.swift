import CoreBluetooth
import XCTest
@testable import ios_tuvali_library

/// Discovery, reads and writes, each answered (or not) by CoreBluetooth.
final class AsyncGattClientOperationsTests: XCTestCase {
    private var bluetooth: MockCoreBluetooth!
    private var peripheral: MockGattPeripheral!
    private var client: AsyncGattClient!
    private let attError = NSError(domain: CBATTErrorDomain, code: CBATTError.Code.unlikelyError.rawValue)

    override func setUp() async throws {
        bluetooth = MockCoreBluetooth()
        peripheral = MockGattPeripheral()
        client = try await bluetooth.connectedClient(to: peripheral)
    }

    // MARK: discovery

    func testDiscoverServicesReturnsTheServicesIosDiscovered() async throws {
        let client = client!
        let discovery = Task { try await client.discoverServices([MockGattPeripheral.serviceUuid]) }
        try await eventually { self.bluetooth.onQueue { self.peripheral.discoverServicesRequests.count == 1 } }

        bluetooth.deliver {
            self.peripheral.markDiscovered()
            self.client.discoveredServices(error: nil)
        }

        let services = try await discovery.value
        XCTAssertEqual(services.map(\.uuid), [MockGattPeripheral.serviceUuid])
    }

    func testDiscoverServicesThrowsGattOperationFailedErrorWhenIosReportsADiscoveryError() async throws {
        let client = client!
        let discovery = Task { try await client.discoverServices([MockGattPeripheral.serviceUuid]) }
        try await eventually { self.bluetooth.onQueue { self.peripheral.discoverServicesRequests.count == 1 } }

        bluetooth.deliver { self.client.discoveredServices(error: self.attError) }

        let error = await errorThrown(by: discovery)
        XCTAssertEqual((error as? GattOperationFailedError)?.operation, .discoverServices)
    }

    func testFindServiceDiscoversTheServiceAndThenItsCharacteristics() async throws {
        let client = client!
        let search = Task { try await client.findService(MockGattPeripheral.serviceUuid) }
        try await eventually { self.bluetooth.onQueue { self.peripheral.discoverServicesRequests.count == 1 } }

        bluetooth.deliver {
            self.peripheral.markDiscovered()
            self.client.discoveredServices(error: nil)
        }
        try await eventually { self.bluetooth.onQueue { self.peripheral.discoverCharacteristicsRequests.count == 1 } }
        bluetooth.deliver { self.client.discoveredCharacteristics(for: self.peripheral.service, error: nil) }

        let service = try await search.value
        XCTAssertEqual(service.uuid, MockGattPeripheral.serviceUuid)
        let characteristicsRequested = bluetooth.onQueue { peripheral.discoverCharacteristicsRequests }
        XCTAssertEqual(characteristicsRequested, [MockGattPeripheral.serviceUuid])
    }

    func testFindServiceRetriesDiscoveryUntilTheServiceAppears() async throws {
        let client = client!
        let search = Task { try await client.findService(MockGattPeripheral.serviceUuid, retryDelay: 0.01) }
        try await eventually { self.bluetooth.onQueue { self.peripheral.discoverServicesRequests.count == 1 } }

        // the first discovery comes back without the service
        bluetooth.deliver {
            self.peripheral.services = []
            self.client.discoveredServices(error: nil)
        }
        try await eventually { self.bluetooth.onQueue { self.peripheral.discoverServicesRequests.count == 2 } }
        bluetooth.deliver {
            self.peripheral.markDiscovered()
            self.client.discoveredServices(error: nil)
        }
        try await eventually { self.bluetooth.onQueue { self.peripheral.discoverCharacteristicsRequests.count == 1 } }
        bluetooth.deliver { self.client.discoveredCharacteristics(for: self.peripheral.service, error: nil) }

        let service = try await search.value
        XCTAssertEqual(service.uuid, MockGattPeripheral.serviceUuid)
    }

    func testFindServiceThrowsGattAttributeNotFoundErrorWhenTheServiceIsStillMissingAfterAllAttempts() async throws {
        let client = client!
        let search = Task {
            try await client.findService(MockGattPeripheral.serviceUuid, attempts: 2, retryDelay: 0.01)
        }

        for attempt in 1...2 {
            try await eventually {
                self.bluetooth.onQueue { self.peripheral.discoverServicesRequests.count == attempt }
            }
            bluetooth.deliver {
                self.peripheral.services = []
                self.client.discoveredServices(error: nil)
            }
        }

        let error = await errorThrown(by: search)
        XCTAssertTrue(error is GattAttributeNotFoundError, "\(String(describing: error))")
    }

    func testMaximumWriteLengthIsWhatIosAllowsForAWriteWithoutResponse() {
        // CoreBluetooth negotiates the MTU itself; this is the MTU minus 3 bytes
        bluetooth.onQueue { peripheral.maximumWriteLength = 244 }

        let length = bluetooth.onQueue { client.maximumWriteLength }

        XCTAssertEqual(length, 244)
    }

    // MARK: read

    func testReadReturnsTheCharacteristicValueIosDelivered() async throws {
        bluetooth.onQueue { peripheral.markDiscovered() }
        let client = client!
        let read = Task { try await client.read(MockGattPeripheral.readUuid) }
        try await eventually {
            self.bluetooth.onQueue { self.peripheral.readRequests == [MockGattPeripheral.readUuid] }
        }

        bluetooth.deliver {
            self.peripheral.readCharacteristic.value = Data([0x01, 0x02])
            self.client.updatedValue(for: self.peripheral.readCharacteristic, error: nil)
        }

        let value = try await read.value
        XCTAssertEqual(value, [0x01, 0x02])
    }

    func testReadThrowsGattOperationFailedErrorWhenIosReportsAReadError() async throws {
        bluetooth.onQueue { peripheral.markDiscovered() }
        let client = client!
        let read = Task { try await client.read(MockGattPeripheral.readUuid) }
        try await eventually { self.bluetooth.onQueue { self.peripheral.readRequests.count == 1 } }

        bluetooth.deliver { self.client.updatedValue(for: self.peripheral.readCharacteristic, error: self.attError) }

        let error = await errorThrown(by: read)
        XCTAssertEqual((error as? GattOperationFailedError)?.operation, .readCharacteristic)
    }

    func testReadThrowsGattAttributeNotFoundErrorWhenTheCharacteristicDoesNotExist() async throws {
        bluetooth.onQueue { peripheral.markDiscovered() }
        let missing = CBUUID(string: "0000a0ff-0000-1000-8000-00805f9b34fb")
        let client = client!

        let read = Task { try await client.read(missing) }

        let error = await errorThrown(by: read)
        XCTAssertTrue(error is GattAttributeNotFoundError, "\(String(describing: error))")
    }

    func testReadThrowsGattAttributeNotFoundErrorWhenTheServiceDoesNotExist() async throws {
        // nothing discovered yet, so the service is unknown
        let client = client!

        let read = Task { try await client.read(MockGattPeripheral.readUuid) }

        let error = await errorThrown(by: read)
        XCTAssertTrue(error is GattAttributeNotFoundError, "\(String(describing: error))")
    }

    // MARK: write without response

    func testWriteWithoutResponseSendsTheValueWithTheNoResponseWriteType() async throws {
        bluetooth.onQueue { peripheral.markDiscovered() }

        try await client.writeWithoutResponse(MockGattPeripheral.writeUuid, [0x01, 0x02])

        let writes = bluetooth.onQueue { peripheral.writes }
        XCTAssertEqual(writes.map(\.characteristic), [MockGattPeripheral.writeUuid])
        XCTAssertEqual(writes.map(\.value), [[0x01, 0x02]])
        XCTAssertEqual(writes.map(\.type), [.withoutResponse])
    }

    func testWriteWithoutResponseWaitsUntilIosCanSendWhenItsBufferIsFull() async throws {
        bluetooth.onQueue {
            peripheral.markDiscovered()
            peripheral.canSendWriteWithoutResponse = false
        }
        let client = client!
        let write = Task {
            try await client.writeWithoutResponse(MockGattPeripheral.writeUuid, [0x01])
        }

        try await Task.sleep(nanoseconds: 50_000_000)
        let writesWhileBufferFull = bluetooth.onQueue { peripheral.writes.count }
        bluetooth.deliver {
            self.peripheral.canSendWriteWithoutResponse = true
            self.client.readyToSendWriteWithoutResponse()
        }
        try await write.value

        XCTAssertEqual(writesWhileBufferFull, 0)
        XCTAssertEqual(bluetooth.onQueue { peripheral.writes.count }, 1)
    }

    func testWriteWithoutResponseThrowsGattOperationTimeoutErrorWhenIosNeverHasRoom() async throws {
        bluetooth.onQueue {
            peripheral.markDiscovered()
            peripheral.canSendWriteWithoutResponse = false
        }
        let client = client!

        let write = Task {
            try await client.writeWithoutResponse(MockGattPeripheral.writeUuid, [0x01])
        }

        let error = await errorThrown(by: write)
        XCTAssertEqual((error as? GattOperationTimeoutError)?.operation, .writeCharacteristic)
    }
}
