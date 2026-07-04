import Foundation

// MARK: - RecoveryPolicy

/// 传输中断恢复队列的配置策略。
///
/// M1 harness 此前在传输遇到 transport-loss 时最多只重试一次。
/// `RecoveryPolicy` 把这个循环泛化，让 harness 可以按可配置次数重试，
/// 并在每次重试之间插入指数退避和小幅抖动，同时仍可退回到历史的
/// "最多重试一次" 默认行为，保证现有真机脚本不受影响。
///
/// 这个类型是纯值类型：它只决定 *是否要重试* 和 *等待多久*。
/// 实际的睡眠由调用方通过注入的 `RecoverySleeper` 闭包执行，
/// 这样策略本身可以不依赖真实时间延迟地被单元测试覆盖。
///
/// 语义（另见 docs/protocol-runtime.md "Transport-Loss Retry" 章节）：
///
/// - `maxAttempts` 计数的是首次尝试 *之后* 允许的额外重连次数，与 harness
///   日志里的 `retry_attempts` 字段对齐。值为 `1` 即复刻历史"最多重试一次"。
/// - 首次失败的下标是 `0`（即首次传输尝试）。只要
///   `attemptIndex < maxAttempts`，就还允许再重试一次。
/// - 退避按指数增长：`baseDelayMs * 2^(attemptIndex - 1)`，并以
///   `maxDelayMs` 为上限。再叠加 `±jitterPercent` 的抖动，避免多个并发
///   重试同时撞线。
/// - 抖动系数为 `0` 时关闭抖动，返回确定性延迟，单元测试据此断言。
public struct RecoveryPolicy: Sendable {
    /// 首次尝试之后允许的额外重连次数。
    /// `0` 完全关闭恢复；`1` 复刻历史的单次重试行为。
    public let maxAttempts: Int

    /// 首次重试退避的基准毫秒数。
    public let baseDelayMs: Int64

    /// 退避延迟的毫秒数上限。
    public let maxDelayMs: Int64

    /// 退避的抖动比例，取值 `[0, 1]`。
    /// `0` 给出确定性延迟；`0.25` 最多叠加 ±25% 抖动。
    public let jitterFactor: Double

    /// 默认策略：单次重试 + 500ms 基准退避，与恢复队列之前的 harness 行为一致。
    /// 在 `--retry-on-transport-loss` 被设置但没有 `--max-retry-attempts` 时使用。
    public static let defaultSingleRetry = RecoveryPolicy(
        maxAttempts: 1,
        baseDelayMs: 500,
        maxDelayMs: 30_000,
        jitterFactor: 0
    )

    /// 完全关闭恢复的策略。在 `--retry-on-transport-loss` 未设置时使用。
    public static let disabled = RecoveryPolicy(
        maxAttempts: 0,
        baseDelayMs: 0,
        maxDelayMs: 0,
        jitterFactor: 0
    )

    public init(
        maxAttempts: Int,
        baseDelayMs: Int64,
        maxDelayMs: Int64,
        jitterFactor: Double
    ) {
        precondition(maxAttempts >= 0, "maxAttempts must be non-negative")
        precondition(baseDelayMs >= 0, "baseDelayMs must be non-negative")
        precondition(maxDelayMs >= 0, "maxDelayMs must be non-negative")
        precondition(
            jitterFactor >= 0 && jitterFactor <= 1,
            "jitterFactor must be in [0, 1]"
        )
        self.maxAttempts = maxAttempts
        self.baseDelayMs = baseDelayMs
        self.maxDelayMs = maxDelayMs
        self.jitterFactor = jitterFactor
    }

    /// 在 `attemptIndex` 处的失败之后是否还允许再重试一次。
    /// `attemptIndex == 0` 表示首次尝试。
    ///
    /// 调用方在每次失败后递增 `attemptIndex`，因此最后一次允许的重试发生在
    /// 下标 `maxAttempts` 处（含首次尝试在内共 `maxAttempts + 1` 次尝试）。
    public func shouldRetry(afterFailureAt attemptIndex: Int) -> Bool {
        attemptIndex < maxAttempts
    }

    /// 计算跟在 `attemptIndex` 处的失败之后、下一次重试前应等待的退避毫秒数。
    ///
    /// 退避按 `baseDelayMs * 2^(attemptIndex - 1)` 增长（因此首次失败
    /// `attemptIndex == 1` 之后等待 `baseDelayMs`），并以 `maxDelayMs` 为上限。
    /// 当 `jitterFactor > 0` 时按 ±`jitterFactor` 扰动。
    /// 确定性部分通过 `deterministicDelayMs(forAttempt:)` 暴露，
    /// 测试可以断言未抖动的值。
    ///
    /// - Parameter randomSource: 返回 `[0, 1)` 内 `Double` 的闭包。测试注入
    ///   固定值让抖动可复现；生产代码传入 `Double.random(in:)`。
    public func recoveryDelayMs(
        forAttempt attemptIndex: Int,
        randomSource: @Sendable () -> Double = { Double.random(in: 0..<1) }
    ) -> Int64 {
        guard attemptIndex > 0 else {
            // 首次尝试之前从不睡眠。
            return 0
        }
        let deterministic = deterministicDelayMs(forAttempt: attemptIndex)
        guard jitterFactor > 0, deterministic > 0 else {
            return deterministic
        }
        // 把 randomSource() 从 [0,1) 映射到 [1-jitter, 1+jitter]。
        let scale = 1 + (randomSource() * 2 - 1) * jitterFactor
        return max(0, Int64(Double(deterministic) * scale))
    }

    /// 未应用抖动时的退避毫秒数。暴露给测试和诊断，使确定性调度可验证，
    /// 不依赖随机源。
    public func deterministicDelayMs(forAttempt attemptIndex: Int) -> Int64 {
        guard attemptIndex > 0 else {
            return 0
        }
        // attemptIndex == 1 -> baseDelayMs * 2^0 == baseDelayMs。
        let exponent = attemptIndex - 1
        // 防止过大指数导致溢出；反正最终都要被 maxDelayMs 截断。
        let raw: Int64
        if exponent >= 63 {
            raw = maxDelayMs
        } else {
            let shifted = Int64(1) << exponent
            // 检测 baseDelayMs * shifted 是否溢出；溢出则直接截断。
            let product = baseDelayMs.multipliedReportingOverflow(by: shifted)
            raw = product.overflow ? maxDelayMs : product.partialValue
        }
        return min(raw, maxDelayMs)
    }
}

// MARK: - RecoverySleeper

/// 按给定毫秒数挂起执行的闭包类型。
/// 通过注入让单元测试可以记录请求的延迟而不真正睡眠。
public typealias RecoverySleeper = @Sendable (Int64) -> Void

/// 默认睡眠器，调用 `Thread.sleep(forTimeInterval:)`。
/// 在 harness 没有注入测试睡眠器时使用。
public let defaultRecoverySleeper: RecoverySleeper = { delayMs in
    guard delayMs > 0 else { return }
    Thread.sleep(forTimeInterval: Double(delayMs) / 1000.0)
}

// MARK: - runTransferWithRecovery

/// 单次传输尝试的结果。`success` 携带最终结果；`failure` 携带可观察的错误，
/// 调用方据此决定是否重试。
public enum TransferRecoveryOutcome<Result: Sendable>: Sendable {
    case success(Result)
    case failure(Error)
}

/// 把"传输 + 恢复"循环抽成可测试的纯执行器。
///
/// harness 的 download/upload 命令把单次传输闭包 `attempt` 传进来，
/// `runTransferWithRecovery` 负责按 `policy` 在失败时重试、退避睡眠并
/// 把最终结果或错误抛回。`sleeper` 默认指向 `defaultRecoverySleeper`，
/// 测试注入记录型 sleeper 即可断言退避时序而不真正睡眠。
///
/// - Parameters:
///   - policy: 恢复策略，决定重试次数和退避。
///   - sleeper: 退避睡眠闭包，默认 `defaultRecoverySleeper`。
///   - isRetryable: 判定某个错误是否值得重试。transport-loss/timeout 类
///     错误应返回 `true`；协议级错误（如 notFound）应返回 `false`。
///   - canResume: 在重试前额外检查是否仍具备恢复条件（例如 sidecar 是否
///     存在）。返回 `false` 时即使策略允许也不重试。
///   - attempt: 单次传输闭包，接受当前尝试下标（0 起），返回成功或失败。
///     闭包内部应自行在新 session 上重连并基于 sidecar 续传。
///   - onRetry: 可选回调，在每次决定重试后、睡眠前调用，便于 harness
///     打 stderr 日志，也便于测试断言重试发生了几次。
@discardableResult
public func runTransferWithRecovery<Result: Sendable>(
    policy: RecoveryPolicy,
    sleeper: RecoverySleeper = defaultRecoverySleeper,
    isRetryable: @Sendable (Error) -> Bool,
    canResume: @Sendable () -> Bool,
    attempt: @Sendable (Int) throws -> Result,
    onRetry: (@Sendable (Int, Int64, Error) -> Void)? = nil
) throws -> Result {
    var attemptIndex = 0
    while true {
        do {
            let result = try attempt(attemptIndex)
            return result
        } catch {
            let failure = error
            let allowed = policy.shouldRetry(afterFailureAt: attemptIndex)
                && isRetryable(failure)
                && canResume()
            guard allowed else {
                throw failure
            }
            // 计算下一次重试（attemptIndex + 1）前的退避。
            let delayMs = policy.recoveryDelayMs(
                forAttempt: attemptIndex + 1,
                randomSource: { Double.random(in: 0..<1) }
            )
            onRetry?(attemptIndex + 1, delayMs, failure)
            sleeper(delayMs)
            attemptIndex += 1
        }
    }
}

