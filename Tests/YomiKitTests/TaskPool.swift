import Foundation

/// Runs `work` on a dispatch queue, so it does not hold a thread of Swift's cooperative pool while it runs.
/// Vision waits on work it queues to that pool, so enough tests calling Vision synchronously at once use up
/// every thread and deadlock. The app and `yomi` process sheets on dispatch queues and never do.
func offTheTaskPool<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global().async { continuation.resume(with: Result(catching: work)) }
    }
}
