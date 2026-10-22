import Foundation

/// Runs an async operation with a hard deadline. Unlike a task group, this returns at the
/// deadline even when the operation is stuck in a synchronous call (e.g. a Keychain prompt),
/// so one blocked source can never stall a refresh.
enum Deadline {
    static func run<T: Sendable>(
        seconds: Double,
        label: String,
        _ operation: @escaping @Sendable () async throws -> T
    ) async -> Result<T, Error> {
        await withCheckedContinuation { (continuation: CheckedContinuation<Result<T, Error>, Never>) in
            let once = ResumeOnce(continuation)
            let work = Task {
                do {
                    once.resume(.success(try await operation()))
                } catch {
                    once.resume(.failure(error))
                }
            }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                work.cancel()
                once.resume(.failure(GrokError.network("\(label) timed out after \(Int(seconds))s")))
            }
        }
    }
}

private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Result<T, Error>, Never>?

    init(_ continuation: CheckedContinuation<Result<T, Error>, Never>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<T, Error>) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(returning: result)
    }
}
