import Foundation

/// Only a quota preflight rejection is safe to retry automatically. Reuse the
/// same request body/ID; never retry uncertain translation or charging failures.
@MainActor
enum SharedQuotaRetry {
    static func run<T>(
        delay: () async throws -> Void = { try await Task.sleep(for: .milliseconds(600)) },
        operation: () async throws -> T
    ) async throws -> T {
        do { return try await operation() }
        catch let error as TrialServiceError where error.code == "usage_unavailable" {
            try Task.checkCancellation()
            try await delay()
            try Task.checkCancellation()
            return try await operation()
        }
    }
}
