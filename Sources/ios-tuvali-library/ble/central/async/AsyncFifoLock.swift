import Foundation

/// A first-in, first-out lock for async code: callers get it in the order they asked.
/// Its state lives on [queue], like everything else in the Bluetooth layer, so it is safe to share
/// between tasks.
final class AsyncFifoLock: @unchecked Sendable {
    private let queue: DispatchQueue
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    func lock() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                if self.isLocked {
                    self.waiters.append(continuation)
                } else {
                    self.isLocked = true
                    continuation.resume()
                }
            }
        }
    }

    func unlock() {
        queue.async {
            if self.waiters.isEmpty {
                self.isLocked = false
            } else {
                self.waiters.removeFirst().resume()
            }
        }
    }
}

/// Set on the Bluetooth queue when the task waiting for an operation is cancelled; read only there.
final class CancellationFlag: @unchecked Sendable {
    var isCancelled = false
}
