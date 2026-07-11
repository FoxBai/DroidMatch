import Foundation

/// Lock-protected observations and test gates for the mixed transfer server.
final class AsyncMixedTransferTestServerState: @unchecked Sendable {
    private let lock = NSLock()
    private let completion = DispatchSemaphore(value: 0)
    private let uploadAcknowledgementRelease = DispatchSemaphore(value: 0)
    private let downloadRefillRelease = DispatchSemaphore(value: 0)
    private var finished = false
    private var successful = false
    private var uploadBytes = Data()
    private var openedUploadSourcePath = ""
    private var uploadChunkCount = 0
    private var cancellationUploadChunkReceived = false
    private var firstDownloadAcknowledgementReceived = false
    private var cancellationDownloadAcknowledgementReceived = false

    var downloadRequestID: UInt64 = 0
    var uploadRequestID: UInt64 = 0
    var cancellationUploadRequestID: UInt64 = 0
    var cancellationDownloadRequestID: UInt64 = 0
    var downloadAcknowledgementCount = 0

    func appendUpload(_ data: Data) -> Int {
        lock.lock()
        let index = uploadChunkCount
        uploadChunkCount += 1
        uploadBytes.append(data)
        lock.unlock()
        return index
    }

    func setUploadSourcePath(_ value: String) {
        lock.lock()
        openedUploadSourcePath = value
        lock.unlock()
    }

    func uploadSourcePath() -> String {
        lock.lock()
        defer { lock.unlock() }
        return openedUploadSourcePath
    }

    func currentUploadChunkCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return uploadChunkCount
    }

    func markCancellationUploadChunkReceived() {
        lock.lock()
        cancellationUploadChunkReceived = true
        lock.unlock()
    }

    func didReceiveCancellationUploadChunk() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancellationUploadChunkReceived
    }

    func markFirstDownloadAcknowledgementReceived() {
        lock.lock()
        firstDownloadAcknowledgementReceived = true
        lock.unlock()
    }

    func didReceiveFirstDownloadAcknowledgement() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return firstDownloadAcknowledgementReceived
    }

    func waitForDownloadRefillRelease() {
        downloadRefillRelease.wait()
    }

    func releaseDownloadRefill() {
        downloadRefillRelease.signal()
    }

    func markCancellationDownloadAcknowledgementReceived() {
        lock.lock()
        cancellationDownloadAcknowledgementReceived = true
        lock.unlock()
    }

    func didReceiveCancellationDownloadAcknowledgement() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancellationDownloadAcknowledgementReceived
    }

    func waitForUploadAcknowledgementRelease() {
        uploadAcknowledgementRelease.wait()
    }

    func releaseUploadAcknowledgements() {
        uploadAcknowledgementRelease.signal()
    }

    func uploadData() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return uploadBytes
    }

    func finish(success: Bool) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        successful = success
        lock.unlock()
        completion.signal()
    }

    func wait() -> Bool {
        guard completion.wait(timeout: .now() + 2) == .success else {
            return false
        }
        lock.lock()
        defer { lock.unlock() }
        return successful
    }
}
