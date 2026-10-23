@preconcurrency import CoreBluetooth
import Foundation

/// The GATT operations the client runs, one at a time.
enum GattOperation: String {
    case connect
    case discoverServices
    case discoverCharacteristics
    case readCharacteristic
    case writeCharacteristic
    case enableNotifications
    case disableNotifications
}

/// Why the GATT link went down without us closing it.
enum LinkLossReason: Equatable {
    case remoteDisconnected
    /// Bluetooth was switched off or reset, or the app lost permission to use it.
    case bluetoothTurnedOff
}

/// Where the client's connection stands; `lost` says why the link went down.
enum GattConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    /// The link went down without us closing it.
    case lost(LinkLossReason)
}

/// A value the remote GATT server pushed to us through a notification or indication.
struct GattNotification: Equatable {
    let characteristicUuid: CBUUID
    let value: [UInt8]
}

/// How long to wait for iOS to answer before giving up on a GATT operation.
struct GattTimeouts {
    var connect: TimeInterval = 10
    var operation: TimeInterval = 5
}
