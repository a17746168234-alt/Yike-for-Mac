import Foundation
struct TrialServiceError: Error { let code: String }
@main struct Tests {
    @MainActor static func main() async throws {
        var calls = 0
        let result: Int = try await SharedQuotaRetry.run(delay: {}) {
            calls += 1
            if calls == 1 { throw TrialServiceError(code: "usage_unavailable") }
            return 42
        }
        precondition(result == 42 && calls == 2)
        calls = 0
        do {
            let _: Int = try await SharedQuotaRetry.run(delay: {}) {
                calls += 1; throw TrialServiceError(code: "usage_unavailable")
            }
            fatalError("must stop after second failure")
        } catch { precondition(calls == 2) }
        for code in ["network", "pool_empty", "upstream_failed", "login_required", "request_processed"] {
            calls = 0
            do {
                let _: Int = try await SharedQuotaRetry.run(delay: {}) {
                    calls += 1; throw TrialServiceError(code: code)
                }
                fatalError("must fail")
            } catch { precondition(calls == 1) }
        }
        calls = 0
        do {
            let _: Int = try await SharedQuotaRetry.run(delay: { throw CancellationError() }) {
                calls += 1; throw TrialServiceError(code: "usage_unavailable")
            }
            fatalError("must cancel")
        } catch { precondition(calls == 1) }
        print("PASS: quota retry success, bounded failures, no uncertain retries, cancellation")
    }
}
