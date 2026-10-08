import Foundation
import CoreBluetooth

/// Validate the entire ATT batch before applying any writes; respond once per batch.
@available(iOS 13.0, *)
enum VerifierWriteBatch {
    struct Write {
        let uuid: CBUUID
        let properties: CBCharacteristicProperties
        let offset: Int
        let value: Data?
    }

    static func process(_ writes: [Write], onWrite: (CBUUID, Data) -> Void,
                        respond: (CBATTError.Code) -> Void) {
        guard !writes.isEmpty else { return }
        let writableUUIDs = [NetworkCharNums.IDENTIFY_REQUEST_CHAR_UUID,
                             NetworkCharNums.RESPONSE_SIZE_CHAR_UUID,
                             NetworkCharNums.SUBMIT_RESPONSE_CHAR_UUID,
                             NetworkCharNums.TRANSFER_REPORT_REQUEST_CHAR_UUID]
        for write in writes {
            guard writableUUIDs.contains(write.uuid),
                  !write.properties.intersection([.write, .writeWithoutResponse]).isEmpty else {
                respond(.writeNotPermitted)
                return
            }
            // Tuvali writes complete messages, rather than offset-based attribute updates.
            guard write.offset == 0 else {
                respond(.invalidOffset)
                return
            }
            guard write.value != nil else {
                respond(.invalidAttributeValueLength)
                return
            }
        }
        for write in writes {
            onWrite(write.uuid, write.value!)
        }
        respond(.success)
    }
}
