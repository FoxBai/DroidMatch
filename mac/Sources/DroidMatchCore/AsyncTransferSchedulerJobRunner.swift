/// Runs one transfer request without owning queue or job lifecycle state.
///
/// Retry callbacks are synchronous at the coordinator boundary, so the relay
/// serializes them ahead of later progress and terminal events. The scheduler
/// actor remains the sole owner of every resulting state transition.
struct AsyncTransferSchedulerJobRunner: Sendable {
    private let downloadExecutor: AsyncDownloadJobExecutor
    private let uploadExecutor: AsyncUploadJobExecutor

    init(executors: AsyncTransferSchedulerExecutors) {
        self.init(
            downloadExecutor: executors.download,
            uploadExecutor: executors.upload
        )
    }

    init(
        downloadExecutor: @escaping AsyncDownloadJobExecutor,
        uploadExecutor: @escaping AsyncUploadJobExecutor
    ) {
        self.downloadExecutor = downloadExecutor
        self.uploadExecutor = uploadExecutor
    }

    func run(
        _ request: AsyncTransferJobRequest,
        onRetry: @escaping @Sendable (Int, Int64, Error) async -> Void,
        onProgress: @escaping @Sendable (AsyncTransferProgress) async -> Void
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
                    uploadRequest,
                    retryObserver,
                    progressObserver
                ))
            }
            outcome = .success(result)
        } catch is CancellationError {
            outcome = .cancelled
        } catch {
            outcome = .failure(String(describing: error))
        }
        await retryRelay.drain()
        return outcome
    }
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
