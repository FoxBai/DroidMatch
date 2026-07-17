/// Runs one transfer request without owning queue or job lifecycle state.
///
/// Retry callbacks are synchronous at the coordinator boundary, so the relay
/// serializes them ahead of later progress and terminal events. The scheduler
/// actor remains the sole owner of every resulting state transition.
struct AsyncTransferSchedulerJobRunner: Sendable {
    private let downloadExecutor: AsyncDownloadJobExecutor
    private let uploadExecutor: AsyncUploadJobExecutor
    private let uploadCleanupExecutor: AsyncUploadPartialCleanupExecutor

    init(executors: AsyncTransferSchedulerExecutors) {
        self.init(
            downloadExecutor: executors.download,
            uploadExecutor: executors.upload,
            uploadCleanupExecutor: executors.uploadCleanup
        )
    }

    init(
        downloadExecutor: @escaping AsyncDownloadJobExecutor,
        uploadExecutor: @escaping AsyncUploadJobExecutor,
        uploadCleanupExecutor: @escaping AsyncUploadPartialCleanupExecutor = { _, _ in
            throw RpcControlClientError.invalidTransferState(
                "upload partial cleanup executor is unavailable"
            )
        }
    ) {
        self.downloadExecutor = downloadExecutor
        self.uploadExecutor = uploadExecutor
        self.uploadCleanupExecutor = uploadCleanupExecutor
    }

    func run(
        _ request: AsyncTransferJobRequest,
        onRetry: @escaping @Sendable (Int, Int64, Error) async -> Void,
        onProgress: @escaping @Sendable (AsyncTransferProgress) async -> Void,
        onUploadPartialPrepared: @escaping @Sendable (
            AsyncUploadPartialIdentity
        ) async throws -> Void
    ) async -> AsyncTransferJobOutcome {
        let retryRelay = AsyncTransferSchedulerRetryRelay()
        let retryObserver: AsyncTransferRetryObserver = { retry, delay, error in
            retryRelay.enqueue {
                await onRetry(retry, delay, error)
            }
        }
        let progressObserver: AsyncTransferProgressObserver = { progress in
            await retryRelay.drain()
            await onProgress(progress)
        }

        let outcome: AsyncTransferJobOutcome
        do {
            let result: AsyncTransferJobResult
            switch request {
            case let .download(downloadRequest):
                result = .download(try await downloadExecutor(
                    downloadRequest,
                    retryObserver,
                    progressObserver
                ))
            case let .upload(uploadRequest):
                result = .upload(try await uploadExecutor(
                    uploadRequest.observingPartialPreparation(onUploadPartialPrepared),
                    retryObserver,
                    progressObserver
                ))
            }
            outcome = .success(result)
        } catch is CancellationError {
            outcome = .cancelled
        } catch {
            outcome = .failure(AsyncTransferFailureLabel.label(for: error))
        }
        await retryRelay.drain()
        return outcome
    }

    func cleanupUploadPartial(
        request: AsyncUploadCoordinatorRequest,
        identity: AsyncUploadPartialIdentity
    ) async -> AsyncUploadPartialCleanupOutcome {
        do {
            try await uploadCleanupExecutor(request, identity)
            return .success
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failure(AsyncTransferFailureLabel.label(for: error))
        }
    }
}

enum AsyncUploadPartialCleanupOutcome: Sendable, Equatable {
    case success
    case failure(String)
    case cancelled
}

/// Serializes synchronous retry callbacks with later async execution events.
private final class AsyncTransferSchedulerRetryRelay: @unchecked Sendable {
    private let tail = LockedValue<Task<Void, Never>?>(nil)

    func enqueue(_ operation: @escaping @Sendable () async -> Void) {
        tail.update { current in
            let previous = current
            current = Task {
                await previous?.value
                await operation()
            }
        }
    }

    func drain() async {
        await tail.value()?.value
    }
}
