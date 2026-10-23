import Foundation
import os

/// Tuvali's logger. Each one has a tag naming where the messages come from, like an Android log
/// tag; give each class its own: `private let logger = TaggedLogger(tag: "AsyncGattClient")`.
///
/// Messages go to the unified log under the subsystem "io.mosip.tuvali", with the tag as the
/// category, so they can be filtered in Console or with
/// `log stream --predicate 'subsystem == "io.mosip.tuvali" AND category == "AsyncGattClient"'`.
///
/// Messages are logged as public text, as written. Never put key material, credential data,
/// session messages or URIs in one: log what happened, with sizes and statuses, not the values.
///
/// Built on os_log, which iOS 13 has; Apple's own os.Logger needs iOS 14.
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
