import OSLog
import XCTest
@testable import ios_tuvali_library

/// The logger writes to the unified log under Tuvali's subsystem, with its tag as the category.
/// The test reads the log back, so it checks what Console and `log stream` will show.
@available(iOS 15.0, *)
final class TaggedLoggerTests: XCTestCase {
    private let logger = TaggedLogger(tag: "TaggedLoggerTests")

    private func loggedEntry(containing marker: String) throws -> OSLogEntryLog? {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let recent = store.position(timeIntervalSinceEnd: -60)
        let tuvaliOnly = NSPredicate(format: "subsystem == %@", "io.mosip.tuvali")
        return try store.getEntries(at: recent, matching: tuvaliOnly)
            .compactMap { $0 as? OSLogEntryLog }
            .first { $0.composedMessage.contains(marker) }
    }

    func testInfoIsLoggedUnderTheTuvaliSubsystemWithTheTagAsCategory() throws {
        let marker = UUID().uuidString

        logger.info("info \(marker)")

        let entry = try loggedEntry(containing: marker)
        XCTAssertEqual(entry?.subsystem, "io.mosip.tuvali")
        XCTAssertEqual(entry?.category, "TaggedLoggerTests")
        XCTAssertEqual(entry?.level, .info)
    }

    func testWarningIsLoggedAtTheDefaultLevel() throws {
        let marker = UUID().uuidString

        logger.warning("warning \(marker)")

        XCTAssertEqual(try loggedEntry(containing: marker)?.level, .notice)
    }

    func testErrorIsLoggedAtTheErrorLevel() throws {
        let marker = UUID().uuidString

        logger.error("error \(marker)")

        XCTAssertEqual(try loggedEntry(containing: marker)?.level, .error)
    }

    func testTheMessageIsLoggedAsWrittenWithoutRedaction() throws {
        // messages are public text: never put keys, credential data, session bytes or URIs in one
        let marker = UUID().uuidString

        logger.info("link lost: \(marker)")

        XCTAssertEqual(try loggedEntry(containing: marker)?.composedMessage, "link lost: \(marker)")
    }
}
