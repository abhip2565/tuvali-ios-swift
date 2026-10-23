/// The session's ephemeral device key was wiped at the end of the session and can no longer be used.
struct DeviceKeyWipedError: Error, CustomStringConvertible {
    var description: String { "Ephemeral device key was wiped" }
}
