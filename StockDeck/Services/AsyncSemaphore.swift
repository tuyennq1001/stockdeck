import Foundation

/// A tiny async counting semaphore allowing at most `count` concurrent holders.
///
/// Waiters are resumed FIFO as slots free, so a burst of Yahoo chart requests
/// (one per symbol) is capped without ever blocking the main actor. The count
/// check and waiter append happen under a single lock, so no wake-up is lost.
final class AsyncSemaphore: @unchecked Sendable {
    private let lock = NSLock()
    private var count: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(count: Int) {
        self.count = count
    }

    func wait() async {
        lock.lock()
        if count > 0 {
            count -= 1
            lock.unlock()
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(continuation)
            lock.unlock()
        }
    }

    func signal() {
        var toResume: CheckedContinuation<Void, Never>?
        lock.lock()
        if waiters.isEmpty {
            count += 1
        } else {
            toResume = waiters.removeFirst()
        }
        lock.unlock()
        toResume?.resume()
    }
}
