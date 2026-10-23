@preconcurrency import CoreBluetooth
import Foundation

/// Finds a reader advertising the session service UUID (clause 8.3.3.1.1.3).
protocol ReaderFinder: AnyObject {
    /// Scans until a reader that is not in [excludedReaders] advertises [serviceUuid].
    func findReader(serviceUuid: CBUUID, excluding excludedReaders: Set<UUID>) async throws -> GattPeripheral
}

/// ReaderFinder on AsyncBleCentral. It fails at once if Bluetooth is off or is switched off while
/// scanning, and always stops the scan when it finishes or is cancelled.
final class BleReaderFinder: ReaderFinder {
    private let central: AsyncBleCentral

    init(central: AsyncBleCentral) {
        self.central = central
    }

    func findReader(serviceUuid: CBUUID, excluding excludedReaders: Set<UUID>) async throws -> GattPeripheral {
        let scan = central.scan(for: serviceUuid)
        // leaving the loop does not end the scan by itself
        defer { central.stopScan() }
        for try await peripheral in scan where !excludedReaders.contains(peripheral.identifier) {
            return peripheral
        }
        try Task.checkCancellation()
        throw IsoTransportError("The scan ended before a reader was found")
    }
}
