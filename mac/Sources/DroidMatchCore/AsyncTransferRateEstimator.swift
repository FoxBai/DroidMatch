import Foundation

/// A short, time-weighted rate over receiver-confirmed progress samples.
///
/// The estimator deliberately knows nothing about bytes placed on the wire.
/// Samples are absolute checkpoints, and a gap longer than the rolling window
/// starts a fresh baseline instead of averaging a stall into a misleading rate.
struct AsyncTransferRateEstimator: Sendable {
    struct Sample: Sendable, Equatable {
        let confirmedBytes: Int64
        let uptimeNanoseconds: UInt64
    }

    static let defaultWindowNanoseconds: UInt64 = 2_000_000_000
    static let defaultMaximumSamples = 256

    private let windowNanoseconds: UInt64
    private let maximumSamples: Int
    private var samples: [Sample] = []

    private(set) var bytesPerSecond: Double?

    init(
        windowNanoseconds: UInt64 = defaultWindowNanoseconds,
        maximumSamples: Int = defaultMaximumSamples
    ) {
        precondition(windowNanoseconds > 0, "rate window must be positive")
        precondition(maximumSamples >= 2, "rate estimator needs at least two samples")
        self.windowNanoseconds = windowNanoseconds
        self.maximumSamples = maximumSamples
    }

    @discardableResult
    mutating func record(confirmedBytes: Int64, at uptimeNanoseconds: UInt64) -> Bool {
        guard confirmedBytes >= 0 else { return false }
        let sample = Sample(
            confirmedBytes: confirmedBytes,
            uptimeNanoseconds: uptimeNanoseconds
        )
        guard let previous = samples.last else {
            samples = [sample]
            bytesPerSecond = nil
            return true
        }

        // Equal offsets do not move the time baseline forward and therefore
        // cannot inflate the next rate. Regressing clocks/offsets are ignored.
        guard confirmedBytes > previous.confirmedBytes,
              uptimeNanoseconds > previous.uptimeNanoseconds else {
            return false
        }

        if uptimeNanoseconds - previous.uptimeNanoseconds > windowNanoseconds {
            samples = [sample]
            bytesPerSecond = nil
            return true
        }

        samples.append(sample)
        trimWindow(endingAt: uptimeNanoseconds)
        updateRate()
        return true
    }

    mutating func reset() {
        samples.removeAll(keepingCapacity: true)
        bytesPerSecond = nil
    }

    private mutating func trimWindow(endingAt uptimeNanoseconds: UInt64) {
        let cutoff = uptimeNanoseconds > windowNanoseconds
            ? uptimeNanoseconds - windowNanoseconds
            : 0
        // Keep one anchor immediately before the cutoff so the oldest partial
        // interval remains represented in the time-weighted calculation.
        while samples.count > 2, samples[1].uptimeNanoseconds <= cutoff {
            samples.removeFirst()
        }
        if samples.count > maximumSamples {
            samples.removeFirst(samples.count - maximumSamples)
        }
    }

    private mutating func updateRate() {
        guard let first = samples.first,
              let last = samples.last,
              last.confirmedBytes > first.confirmedBytes,
              last.uptimeNanoseconds > first.uptimeNanoseconds else {
            bytesPerSecond = nil
            return
        }
        let byteDelta = Double(last.confirmedBytes - first.confirmedBytes)
        let seconds = Double(last.uptimeNanoseconds - first.uptimeNanoseconds)
            / 1_000_000_000
        bytesPerSecond = byteDelta / seconds
    }
}
