@preconcurrency import CoreBluetooth
import Foundation

/// What a transport needs from a connected GATT client. AsyncGattClient is the real one; tests
/// stand in for it with a scripted reader.
protocol GattClient: AnyObject {
    /// Values pushed by the remote server, in arrival order. Meant for a single listener.
    var notifications: AsyncThrowingStream<GattNotification, Error> { get }

    /// Discovers [serviceUuid] and its characteristics, retrying while discovery comes back incomplete.
    func findService(_ serviceUuid: CBUUID) async throws -> CBService
    func read(serviceUuid: CBUUID, characteristicUuid: CBUUID) async throws -> [UInt8]
    func writeWithoutResponse(serviceUuid: CBUUID, characteristicUuid: CBUUID, value: [UInt8]) async throws
    func enableNotifications(serviceUuid: CBUUID, characteristicUuid: CBUUID) async throws
    func disableNotifications(serviceUuid: CBUUID, characteristicUuid: CBUUID) async throws

    func currentConnectionState() async -> GattConnectionState
    /// The longest value one write without response can carry: the negotiated ATT MTU minus 3.
    func currentMaximumWriteLength() async -> Int

    /// Disconnects and releases everything. Pending and later operations fail.
    func close()
}
