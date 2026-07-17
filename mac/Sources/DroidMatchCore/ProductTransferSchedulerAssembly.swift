import Foundation

/// Immutable, session-bound dependencies for product transfer scheduling.
///
/// This value accepts the credential already proven by the current authenticated
/// session and revalidates its fingerprint before creating an invalidatable
/// retry-client gate. It also wraps every local endpoint access in the platform
/// provider's lease. It owns no session generation, build task, published
/// scheduler, or teardown decision; those stay in the session actor.
/// 中文：此值复核当前会话已证明的配对凭据、装配 retry gate，并为每次本地文件 I/O 获取授权
/// lease；它不持有 generation、build Task、已发布 scheduler 或 teardown 决策。
struct ProductTransferSchedulerAssembly: Sendable {
    private static let maxConcurrentJobs = 2

    let gate: ProductTransferSessionGate
    let accessProvider: any LocalFileAccessProviding
    let persistenceStore: TransferQueuePersistenceStore?
    let localFileAccessOwnerID: LocalFileAccessOwnerID

    private let downloadExecutor: AsyncDownloadJobExecutor
    private let uploadExecutor: AsyncUploadJobExecutor
    private let uploadCleanupExecutor: AsyncUploadPartialCleanupExecutor

    init(
        lease: DeviceConnectionLease,
        selectedFingerprint: Data,
        credentials: PairingCredentials,
        persistenceDirectoryURL: URL?,
        localFileAccessProviderFactory: @Sendable (
            LocalFileAccessOwnerID
        ) -> any LocalFileAccessProviding
    ) throws {
        guard let ownerID = LocalFileAccessOwnerID(
            authenticatedDeviceFingerprint: selectedFingerprint
        ) else {
            throw ProductDeviceSessionError.noPreparedDevice
        }
        guard credentials.deviceIdentityFingerprint == selectedFingerprint else {
            throw ProductDeviceSessionError.credentialsUnavailable
        }
        let persistenceURL = try ProductTransferPersistenceLocation.resolve(
            directory: persistenceDirectoryURL,
            fingerprint: selectedFingerprint
        )
        let persistenceStore = try persistenceURL.map {
            try TransferQueuePersistenceStore(fileURL: $0)
        }
        let gate = ProductTransferSessionGate(
            lease: lease,
            credentials: credentials
        )
        let clientFactory: AsyncRpcControlClientFactory = { attemptIndex in
            try await gate.makeClient(attemptIndex: attemptIndex)
        }
        let downloadCoordinator = AsyncDownloadCoordinator(clientFactory: clientFactory)
        let uploadCoordinator = AsyncUploadCoordinator(clientFactory: clientFactory)
        let accessProvider = localFileAccessProviderFactory(ownerID)

        self.gate = gate
        self.accessProvider = accessProvider
        self.persistenceStore = persistenceStore
        localFileAccessOwnerID = ownerID
        downloadExecutor = { request, retry, progress in
            let destination = try await accessProvider.acquireDownloadDestination(
                to: request.destinationURL
            )
            defer { destination.release() }
            let directoryContext = (destination as? any LocalDownloadDirectoryContextProviding)?
                .directoryContext
            return try await downloadCoordinator.download(
                request,
                expectedDirectoryIdentity: destination.directoryIdentity,
                directoryContext: directoryContext,
                onRetry: retry,
                onProgress: progress
            )
        }
        uploadExecutor = { request, retry, progress in
            let access = try await accessProvider.acquireAccess(to: request.sourceURL)
            defer { access.release() }
            return try await uploadCoordinator.upload(
                request,
                onRetry: retry,
                onProgress: progress
            )
        }
        uploadCleanupExecutor = { request, identity in
            try await uploadCoordinator.discardPreparedPartial(identity, for: request)
        }
    }

    func makeTransientScheduler() -> AsyncTransferScheduler {
        AsyncTransferScheduler(
            maxConcurrentJobs: Self.maxConcurrentJobs,
            downloadExecutor: downloadExecutor,
            uploadExecutor: uploadExecutor,
            uploadCleanupExecutor: uploadCleanupExecutor,
            localFileAccessOwnerID: localFileAccessOwnerID
        )
    }

    func restoreScheduler(
        from persistenceStore: TransferQueuePersistenceStore,
        manifest: PersistedTransferQueue,
        downloadDirectoryContexts: [String: LocalDownloadDirectoryContext],
        startQueuedJobs: Bool
    ) async throws -> AsyncTransferScheduler {
        try await AsyncTransferScheduler.restoring(
            maxConcurrentJobs: Self.maxConcurrentJobs,
            persistenceStore: persistenceStore,
            manifest: manifest,
            downloadDirectoryContexts: downloadDirectoryContexts,
            downloadExecutor: downloadExecutor,
            uploadExecutor: uploadExecutor,
            uploadCleanupExecutor: uploadCleanupExecutor,
            localFileAccessOwnerID: localFileAccessOwnerID,
            startQueuedJobs: startQueuedJobs
        )
    }

    func restoreSchedulerAfterPersistenceLoadFailure(
        from persistenceStore: TransferQueuePersistenceStore
    ) async throws -> AsyncTransferScheduler {
        try await AsyncTransferScheduler.restoring(
            maxConcurrentJobs: Self.maxConcurrentJobs,
            persistenceStore: persistenceStore,
            initialPersistenceLoadFailed: true,
            downloadExecutor: downloadExecutor,
            uploadExecutor: uploadExecutor,
            uploadCleanupExecutor: uploadCleanupExecutor,
            localFileAccessOwnerID: localFileAccessOwnerID,
            startQueuedJobs: false
        )
    }

}
