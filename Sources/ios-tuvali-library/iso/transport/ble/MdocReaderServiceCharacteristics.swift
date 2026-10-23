@preconcurrency import CoreBluetooth

/// Characteristics of the mdoc reader service, when the reader is the GATT server (Table 12).
enum MdocReaderServiceCharacteristics {
    static let state = CBUUID(string: "00000005-A123-48CE-896B-4C76973373E6")
    static let clientToServer = CBUUID(string: "00000006-A123-48CE-896B-4C76973373E6")
    static let serverToClient = CBUUID(string: "00000007-A123-48CE-896B-4C76973373E6")
    static let ident = CBUUID(string: "00000008-A123-48CE-896B-4C76973373E6")

    static let all = [state, clientToServer, serverToClient, ident]
}

/// Values written to or notified on the State characteristic (Table 13).
enum ConnectionStateValue {
    /// Written by the GATT client: ready for the transmission to start.
    static let start: UInt8 = 0x01

    /// Either side: end the transaction.
    static let end: UInt8 = 0x02
}
