import Foundation

/// What a timed operation produced, carried out of its child task.
private enum TimedOutcome<T>: @unchecked Sendable {
    case finished(T)
    case timedOut
}

/// Runs [operation], or gives up after [seconds] and returns nil. On a time-out the operation is
/// cancelled, and this returns only once it has finished, so nothing it does outlives the call.
/// The operation should therefore end soon after its task is cancelled.
func withTimeout<T>(_ seconds: TimeInterval, _ operation: @escaping @Sendable () async throws -> T) async throws -> T? {
    guard seconds.isFinite, seconds >= 0, seconds <= 365 * 24 * 60 * 60 else {
        throw MdocPresentationError.invalidTimeout
    }
    try Task.checkCancellation()
    return try await withThrowingTaskGroup(of: TimedOutcome<T>.self) { group in
        group.addTask { .finished(try await operation()) }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
            return .timedOut
        }
        // whichever ends first decides; the other one is cancelled, and the group waits for it
        defer { group.cancelAll() }
        guard let first = try await group.next() else { preconditionFailure("The group has two tasks") }
        switch first {
        case let .finished(value): return value
        case .timedOut: return nil
        }
    }
}
