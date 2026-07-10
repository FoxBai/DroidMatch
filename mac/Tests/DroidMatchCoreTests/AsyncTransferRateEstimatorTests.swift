import Testing
@testable import DroidMatchCore

@Test func asyncTransferRateEstimatorUsesTimeWeightedRollingWindow() {
    var estimator = AsyncTransferRateEstimator(
        windowNanoseconds: 2_000_000_000,
        maximumSamples: 8
    )

    estimator.record(confirmedBytes: 0, at: 0)
    #expect(estimator.bytesPerSecond == nil)

    estimator.record(confirmedBytes: 100, at: 1_000_000_000)
    #expect(estimator.bytesPerSecond == 100)

    estimator.record(confirmedBytes: 300, at: 2_000_000_000)
    #expect(estimator.bytesPerSecond == 150)

    // The 0-second anchor falls out. The remaining 500 bytes over two seconds
    // prove the rate is weighted by time rather than averaging per-chunk rates.
    estimator.record(confirmedBytes: 600, at: 3_000_000_000)
    #expect(estimator.bytesPerSecond == 250)
}

@Test func asyncTransferRateEstimatorInvalidatesLongGapAndResetsRetryBaseline() {
    var estimator = AsyncTransferRateEstimator(windowNanoseconds: 2_000_000_000)
    estimator.record(confirmedBytes: 0, at: 0)
    estimator.record(confirmedBytes: 100, at: 1_000_000_000)
    #expect(estimator.bytesPerSecond == 100)

    estimator.record(confirmedBytes: 200, at: 4_000_000_000)
    #expect(estimator.bytesPerSecond == nil)
    estimator.record(confirmedBytes: 300, at: 5_000_000_000)
    #expect(estimator.bytesPerSecond == 100)

    estimator.reset()
    #expect(estimator.bytesPerSecond == nil)
    estimator.record(confirmedBytes: 300, at: 20_000_000_000)
    #expect(estimator.bytesPerSecond == nil)
    estimator.record(confirmedBytes: 500, at: 21_000_000_000)
    #expect(estimator.bytesPerSecond == 200)
}

@Test func asyncTransferRateEstimatorIgnoresDuplicateRegressingAndZeroTimeSamples() {
    var estimator = AsyncTransferRateEstimator()
    let acceptedInitial = estimator.record(confirmedBytes: 100, at: 1_000_000_000)
    let acceptedDuplicate = estimator.record(confirmedBytes: 100, at: 1_500_000_000)
    let acceptedZeroTime = estimator.record(confirmedBytes: 150, at: 1_000_000_000)
    let acceptedRegression = estimator.record(confirmedBytes: 50, at: 1_500_000_000)
    #expect(acceptedInitial)
    #expect(!acceptedDuplicate)
    #expect(!acceptedZeroTime)
    #expect(!acceptedRegression)
    #expect(estimator.bytesPerSecond == nil)

    estimator.record(confirmedBytes: 200, at: 2_000_000_000)
    #expect(estimator.bytesPerSecond == 100)
}

@Test func asyncTransferRateEstimatorBoundsSampleHistory() {
    var estimator = AsyncTransferRateEstimator(
        windowNanoseconds: 100_000_000_000,
        maximumSamples: 2
    )
    estimator.record(confirmedBytes: 0, at: 0)
    estimator.record(confirmedBytes: 100, at: 1_000_000_000)
    estimator.record(confirmedBytes: 400, at: 2_000_000_000)

    // A two-sample cap must discard the 0-byte anchor. The result is therefore
    // the latest 300 bytes / 1 second, not 400 bytes / 2 seconds.
    #expect(estimator.bytesPerSecond == 300)
}
