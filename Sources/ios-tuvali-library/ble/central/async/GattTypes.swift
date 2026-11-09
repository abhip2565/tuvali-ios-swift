@preconcurrency import CoreBluetooth
import Foundation

enum GattOperation: String {
    case connect
    case discoverServices
    case discoverCharacteristics
    case readCharacteristic
    case writeCharacteristic
    case enableNotifications
    case disableNotifications
}

enum LinkLossReason: Equatable {
    case remoteDisconnected
    /// Bluetooth was switched off or reset, or the app lost permission to use it.
    case bluetoothTurnedOff
}

enum GattConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    /// The link went down without us closing it.
    case lost(LinkLossReason)
}

struct GattNotification: Equatable {
    let characteristicUuid: CBUUID
    let value: [UInt8]
}

struct GattTimeouts {
    var connect: TimeInterval = 10
    var operation: TimeInterval = 5
}

extension CBManagerState {
    /// The state's name for logs: CBManagerState has no readable description of its own.
    var name: String {
        switch self {
        case .unknown: return "unknown"
        case .resetting: return "resetting"
        case .unsupported: return "unsupported"
        case .unauthorized: return "unauthorized"
        case .poweredOff: return "poweredOff"
        case .poweredOn: return "poweredOn"
        @unknown default: return "state \(rawValue)"
        }
    }
}
