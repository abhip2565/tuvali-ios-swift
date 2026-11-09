import Foundation

/// Failures of the async GATT client used by the ISO 18013-5 session.
protocol GattError: Error, CustomStringConvertible {}

struct GattAttributeNotFoundError: GattError {
    let attribute: String
    var description: String { "\(attribute) not found" }
}

struct GattDisconnectedError: GattError, Equatable {
    let reason: LinkLossReason?
    var description: String {
        guard let reason = reason else { return "GATT client is not connected" }
        return "GATT link lost: \(reason)"
    }
}

struct GattOperationFailedError: GattError {
    let operation: GattOperation
    let detail: String
    var description: String { "\(operation) failed: \(detail)" }
}

struct GattOperationTimeoutError: GattError {
    let operation: GattOperation
    let timeout: TimeInterval
    var description: String { "\(operation) got no answer within \(timeout) s" }
}

/// Bluetooth LE scanning is not possible on this device: Bluetooth is unsupported, or the app is not
/// allowed to use it. Not a GattError: scanning happens before any GATT connection.
struct BleScanFailedError: Error, CustomStringConvertible {
    let detail: String
    var description: String { "Bluetooth LE scan failed: \(detail)" }
}

/// A peer sent notifications faster than the application could consume them.
struct GattNotificationOverflowError: GattError {
    var description: String { "GATT notification buffer exceeded; connection closed" }
}
