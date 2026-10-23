import XCTest

/// Fails unless [expression] throws an error of type [errorType].
func XCTAssertThrowsError<T, E: Error>(
    _ expression: @autoclosure () throws -> T,
    ofType errorType: E.Type,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertThrowsError(try expression(), file: file, line: line) { error in
        XCTAssertTrue(error is E, "Expected \(E.self), got \(type(of: error)): \(error)", file: file, line: line)
    }
}
