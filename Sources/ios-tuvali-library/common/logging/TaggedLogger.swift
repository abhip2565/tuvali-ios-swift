import Foundation
import os

/// Unified logging under io.mosip.tuvali, with one category per calling class.
/// Messages are public: never log keys, credentials, session messages, or URIs. Log only
/// operation names, sizes, and statuses. Uses os_log for iOS 13 compatibility.
struct TaggedLogger {
    static let subsystem = "io.mosip.tuvali"

    let tag: String
    private let log: OSLog

    init(tag: String) {
        self.tag = tag
        log = OSLog(subsystem: TaggedLogger.subsystem, category: tag)
    }

    /// Detail for debugging; not kept by the system unless debug logging is turned on.
    func debug(_ message: @autoclosure () -> String) {
        write(message(), as: .debug)
    }

    func info(_ message: @autoclosure () -> String) {
        write(message(), as: .info)
    }

    /// Something unexpected that Tuvali recovered from (Android's Log.w).
    func warning(_ message: @autoclosure () -> String) {
        write(message(), as: .default)
    }

    func error(_ message: @autoclosure () -> String) {
        write(message(), as: .error)
    }

    private func write(_ message: String, as type: OSLogType) {
        guard log.isEnabled(type: type) else { return }
        os_log("%{public}@", log: log, type: type, message)
    }
}
