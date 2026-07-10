import Foundation
import Testing
@testable import DroidMatchCore

// `RecoveryPolicy` 的测试，它是传输中断恢复队列的纯逻辑核心。
// 覆盖重试计数、指数退避、抖动映射、上限截断以及历史的单次重试默认值。
// 策略在 harness 层的集成（download/upload 重试循环）由
// `LocalFrameTestServer` 驱动的 `FrameCodecTests.swift` 覆盖。

@Test func recoveryPolicyDisabledNeverRetries() {
    let policy = RecoveryPolicy.disabled

    #expect(policy.shouldRetry(afterFailureAt: 0) == false)
    #expect(policy.shouldRetry(afterFailureAt: 1) == false)
    #expect(policy.recoveryDelayMs(forAttempt: 1) == 0)
}

@Test func recoveryPolicyDefaultSingleRetryMatchesLegacyBehaviour() {
    let policy = RecoveryPolicy.defaultSingleRetry

    // attempt 0 fails -> retry allowed; attempt 1 fails -> no more retries.
    #expect(policy.shouldRetry(afterFailureAt: 0) == true)
    #expect(policy.shouldRetry(afterFailureAt: 1) == false)

    // Default policy has no jitter, so the delay is deterministic.
    #expect(policy.deterministicDelayMs(forAttempt: 0) == 0)
    #expect(policy.deterministicDelayMs(forAttempt: 1) == 500)
    #expect(policy.recoveryDelayMs(forAttempt: 1, randomSource: { 0 }) == 500)
}

@Test func recoveryPolicyExponentialBackoffDoublesEachAttempt() {
    let policy = RecoveryPolicy(
        maxAttempts: 4,
        baseDelayMs: 100,
        maxDelayMs: 100_000,
        jitterFactor: 0
    )

    // attempt 1 -> 100ms, attempt 2 -> 200ms, attempt 3 -> 400ms, attempt 4 -> 800ms.
    #expect(policy.deterministicDelayMs(forAttempt: 0) == 0)
    #expect(policy.deterministicDelayMs(forAttempt: 1) == 100)
    #expect(policy.deterministicDelayMs(forAttempt: 2) == 200)
    #expect(policy.deterministicDelayMs(forAttempt: 3) == 400)
    #expect(policy.deterministicDelayMs(forAttempt: 4) == 800)

    // Retries are allowed up to and including the 4th retry (attempt index 4).
    #expect(policy.shouldRetry(afterFailureAt: 3) == true)
    #expect(policy.shouldRetry(afterFailureAt: 4) == false)
}

@Test func recoveryPolicyCapsAtMaxDelay() {
    // baseDelayMs large enough that the second backoff would overflow the cap.
    let policy = RecoveryPolicy(
        maxAttempts: 5,
        baseDelayMs: 1_000,
        maxDelayMs: 2_000,
        jitterFactor: 0
    )

    #expect(policy.deterministicDelayMs(forAttempt: 1) == 1_000)
    // attempt 2 -> 1_000 * 2 == 2_000, exactly the cap.
    #expect(policy.deterministicDelayMs(forAttempt: 2) == 2_000)
    // attempt 3 -> 1_000 * 4 == 4_000, capped to 2_000.
    #expect(policy.deterministicDelayMs(forAttempt: 3) == 2_000)
    #expect(policy.deterministicDelayMs(forAttempt: 10) == 2_000)
}

@Test func recoveryPolicyJitterStaysWithinPlusMinusFactor() {
    let policy = RecoveryPolicy(
        maxAttempts: 3,
        baseDelayMs: 1_000,
        maxDelayMs: 100_000,
        jitterFactor: 0.25
    )

    // With a 25% jitter, the first retry (deterministic 1_000ms) should be in
    // [750, 1250]. Assert the bounds at the random-source extremes.
    let lower = policy.recoveryDelayMs(forAttempt: 1, randomSource: { 0 })
    let upper = policy.recoveryDelayMs(forAttempt: 1, randomSource: { 0.999 })
    #expect(lower == 750)
    #expect(upper == 1_249)
}

@Test func recoveryPolicyJitterZeroIsDeterministic() {
    let policy = RecoveryPolicy(
        maxAttempts: 3,
        baseDelayMs: 200,
        maxDelayMs: 100_000,
        jitterFactor: 0
    )

    // No jitter -> the random source is ignored entirely.
    #expect(policy.recoveryDelayMs(forAttempt: 1, randomSource: { 0 }) == 200)
    #expect(policy.recoveryDelayMs(forAttempt: 2, randomSource: { 0.999 }) == 400)
}

@Test func recoveryPolicyInitialAttemptHasNoBackoff() {
    let policy = RecoveryPolicy.defaultSingleRetry

    // 首次尝试（下标 0）之前从不睡眠。
    #expect(policy.recoveryDelayMs(forAttempt: 0, randomSource: { 0.999 }) == 0)
}

// MARK: - runTransferWithRecovery 执行器测试
//
// 以下测试覆盖恢复执行器 `runTransferWithRecovery` 的行为契约：
// 多尝试恢复成功、退避时序、attempt cap 耗尽、不可重试错误立即抛出、
// canResume 阻断重试、onRetry 回调可见性。执行器通过注入的 sleeper 和
// mock 传输闭包验证，不依赖真实时间延迟或网络。

private struct RecoveryTestError: Error, Equatable {
    let kind: String
}

@Test func recoveryExecutorRetriesUntilSuccessAndRespectsBackoff() throws {
    // 策略允许 3 次重试，基准 100ms，无抖动 -> 退避序列应为 100, 200, 400。
    let policy = RecoveryPolicy(
        maxAttempts: 3,
        baseDelayMs: 100,
        maxDelayMs: 100_000,
        jitterFactor: 0
    )
    // 记录每次睡眠的毫秒数；LockedValue 是项目里现成的线程安全包装。
    let slept = LockedValue<[Int64]>([])
    let sleeper: RecoverySleeper = { delayMs in
        slept.update { $0.append(delayMs) }
    }
    // 前 2 次失败（transportLost 类），第 3 次成功。
    let callCount = LockedValue(0)
    let result = try runTransferWithRecovery(
        policy: policy,
        sleeper: sleeper,
        isRetryable: { _ in true },
        canResume: { true },
        attempt: { _ in
            callCount.update { $0 += 1 }
            if callCount.value() <= 2 {
                throw RecoveryTestError(kind: "transportLost")
            }
            return "done"
        }
    )

    #expect(result == "done")
    #expect(callCount.value() == 3)
    // 应在 2 次失败后各睡眠一次：100ms（attempt 1 后）、200ms（attempt 2 后）。
    #expect(slept.value() == [100, 200])
}

@Test func recoveryExecutorStopsAfterMaxAttemptsAndThrowsLastError() {
    let policy = RecoveryPolicy(
        maxAttempts: 2,
        baseDelayMs: 50,
        maxDelayMs: 100_000,
        jitterFactor: 0
    )
    let sleeper: RecoverySleeper = { _ in }
    let attempts = LockedValue(0)
    let onRetryCalls = LockedValue<[(attempt: Int, delayMs: Int64)]>([])

    #expect(throws: RecoveryTestError.self) {
        _ = try runTransferWithRecovery(
            policy: policy,
            sleeper: sleeper,
            isRetryable: { _ in true },
            canResume: { true },
            attempt: { _ in
                attempts.update { $0 += 1 }
                throw RecoveryTestError(kind: "transportLost")
            },
            onRetry: { attempt, delayMs, _ in
                onRetryCalls.update { $0.append((attempt, delayMs)) }
            }
        )
    }

    // 首次 + 2 次重试 = 3 次总尝试。
    #expect(attempts.value() == 3)
    // onRetry 应被调用 2 次（attempt 1 和 attempt 2 前），退避 50 和 100。
    let calls = onRetryCalls.value()
    #expect(calls.count == 2)
    #expect(calls[0].attempt == 1)
    #expect(calls[0].delayMs == 50)
    #expect(calls[1].attempt == 2)
    #expect(calls[1].delayMs == 100)
}

@Test func recoveryExecutorDoesNotRetryNonRetryableError() {
    let policy = RecoveryPolicy.defaultSingleRetry
    let attempts = LockedValue(0)
    let sleeper: RecoverySleeper = { _ in
        Issue.record("sleeper should not be called for non-retryable error")
    }

    #expect(throws: RecoveryTestError.self) {
        _ = try runTransferWithRecovery(
            policy: policy,
            sleeper: sleeper,
            isRetryable: { error in
                // notFound 类错误不应重试。
                guard let err = error as? RecoveryTestError else { return false }
                return err.kind == "transportLost"
            },
            canResume: { true },
            attempt: { _ in
                attempts.update { $0 += 1 }
                throw RecoveryTestError(kind: "notFound")
            }
        )
    }

    // 不可重试错误应只尝试一次，不进入重试循环。
    #expect(attempts.value() == 1)
}

@Test func recoveryExecutorRespectsCanResumeFalse() {
    let policy = RecoveryPolicy.defaultSingleRetry
    let attempts = LockedValue(0)
    let sleeper: RecoverySleeper = { _ in
        Issue.record("sleeper should not be called when canResume is false")
    }

    #expect(throws: RecoveryTestError.self) {
        _ = try runTransferWithRecovery(
            policy: policy,
            sleeper: sleeper,
            isRetryable: { _ in true },
            canResume: { false }, // sidecar 不存在，模拟不可恢复
            attempt: { _ in
                attempts.update { $0 += 1 }
                throw RecoveryTestError(kind: "transportLost")
            }
        )
    }

    // canResume 返回 false 时即便错误可重试也不重试。
    #expect(attempts.value() == 1)
}

@Test func recoveryExecutorDisabledPolicyThrowsImmediately() {
    let policy = RecoveryPolicy.disabled
    let attempts = LockedValue(0)
    let sleeper: RecoverySleeper = { _ in
        Issue.record("sleeper should not be called when policy is disabled")
    }

    #expect(throws: RecoveryTestError.self) {
        _ = try runTransferWithRecovery(
            policy: policy,
            sleeper: sleeper,
            isRetryable: { _ in true },
            canResume: { true },
            attempt: { _ in
                attempts.update { $0 += 1 }
                throw RecoveryTestError(kind: "transportLost")
            }
        )
    }

    #expect(attempts.value() == 1)
}

// MARK: - Async product executor

@Test func asyncRecoveryExecutorRetriesWithCancellableBackoff() async throws {
    let policy = RecoveryPolicy(
        maxAttempts: 3,
        baseDelayMs: 25,
        maxDelayMs: 1_000,
        jitterFactor: 0
    )
    let attempts = LockedValue(0)
    let sleeps = LockedValue<[Int64]>([])
    let result = try await runTransferWithRecoveryAsync(
        policy: policy,
        sleeper: { delayMs in
            sleeps.update { $0.append(delayMs) }
        },
        isRetryable: { _ in true },
        canResume: { true },
        attempt: { _ in
            attempts.update { $0 += 1 }
            if attempts.value() < 3 {
                throw RecoveryTestError(kind: "transportLost")
            }
            return "async-done"
        }
    )

    #expect(result == "async-done")
    #expect(attempts.value() == 3)
    #expect(sleeps.value() == [25, 50])
}

@Test func asyncRecoveryExecutorTreatsAttemptCancellationAsTerminal() async {
    let attempts = LockedValue(0)
    let retryClassifierCalled = LockedValue(false)
    var observedCancellation = false
    do {
        _ = try await runTransferWithRecoveryAsync(
            policy: .defaultSingleRetry,
            sleeper: { _ in },
            isRetryable: { _ in
                retryClassifierCalled.update { $0 = true }
                return true
            },
            canResume: { true },
            attempt: { _ -> String in
                attempts.update { $0 += 1 }
                throw CancellationError()
            }
        )
    } catch is CancellationError {
        observedCancellation = true
    } catch {
        Issue.record("unexpected error: \(error)")
    }

    #expect(observedCancellation)
    #expect(attempts.value() == 1)
    #expect(!retryClassifierCalled.value())
}

@Test func asyncRecoveryExecutorPropagatesBackoffCancellation() async {
    let attempts = LockedValue(0)
    var observedCancellation = false
    do {
        _ = try await runTransferWithRecoveryAsync(
            policy: .defaultSingleRetry,
            sleeper: { _ in throw CancellationError() },
            isRetryable: { _ in true },
            canResume: { true },
            attempt: { _ -> String in
                attempts.update { $0 += 1 }
                throw RecoveryTestError(kind: "transportLost")
            }
        )
    } catch is CancellationError {
        observedCancellation = true
    } catch {
        Issue.record("unexpected error: \(error)")
    }

    #expect(observedCancellation)
    #expect(attempts.value() == 1)
}
