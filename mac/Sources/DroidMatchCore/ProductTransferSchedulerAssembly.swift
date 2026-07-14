import Foundation

/// Immutable, session-bound dependencies for product transfer scheduling.
///
/// This value reloads and revalidates the paired credential before creating an
/// invalidatable retry-client gate. It also wraps every local endpoint access in
/// the platform provider's lease. It owns no session generation, build task,
/// published scheduler, or teardown decision; those stay in the session actor.
/// 中文：此值重新校验配对凭据、装配 retry gate，并为每次本地文件 I/O 获取授权
/// lease；它不持有 generation、build Task、已发布 scheduler 或 teardown 决策。
struct ProductTransferSchedulerAssembly: Sendable {
    private static let maxConcurrentJobs = 2

    let gate: ProductTransferSessionGate
    let accessProvider: any LocalFileAccessProviding
    let persistenceStore: TransferQueuePersistenceStore?
    let localFileAccessOwnerID: LocalFileAccessOwnerID

    private let downloadExecutor: AsyncDownloadJobExecutor
    private let uploadExecutor: AsyncUploadJobExecutor

    init(
        lease: DeviceConnectionLease,
        selectedFingerprint: Data,
        credentialStore: any PairingCredentialStoring,
        persistenceURL: URL?,
        localFileAccessProviderFactory: @Sendable (
            LocalFileAccessOwnerID
        ) -> any LocalFileAccessProviding
    ) throws {
        guard let ownerID = LocalFileAccessOwnerID(
            authenticatedDeviceFingerprint: selectedFingerprint
        ) else {
            throw ProductDeviceSessionError.noPreparedDevice
        }
        let credentials = try Self.loadCredentials(
            selectedFingerprint: selectedFingerprint,
            credentialStore: credentialStore
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
            let access = try await accessProvider.acquireAccess(to: request.destinationURL)
            defer { access.release() }
            return try await downloadCoordinator.download(
                request,
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
    }

    func makeTransientScheduler() -> AsyncTransferScheduler {
        AsyncTransferScheduler(
            maxConcurrentJobs: Self.maxConcurrentJobs,
            downloadExecutor: downloadExecutor,
            uploadExecutor: uploadExecutor,
            localFileAccessOwnerID: localFileAccessOwnerID
        )
    }

    func restoreScheduler(
        from persistenceStore: TransferQueuePersistenceStore,
        startQueuedJobs: Bool
    ) async throws -> AsyncTransferScheduler {
        try await AsyncTransferScheduler.restoring(
            maxConcurrentJobs: Self.maxConcurrentJobs,
            persistenceStore: persistenceStore,
            downloadExecutor: downloadExecutor,
            uploadExecutor: uploadExecutor,
            localFileAccessOwnerID: localFileAccessOwnerID,
            startQueuedJobs: startQueuedJobs
        )
    }

    private static func loadCredentials(
        selectedFingerprint: Data,
        credentialStore: any PairingCredentialStoring
    ) throws -> PairingCredentials {
        let record: PairingCredentialRecord
        do {
            guard let metadata = try credentialStore.list().first(where: {
                $0.deviceIdentityFingerprint == selectedFingerprint
            }) else {
                throw ProductDeviceSessionError.credentialsUnavailable
            }
            record = try credentialStore.load(pairingID: metadata.pairingID)
            guard record.deviceIdentityFingerprint == selectedFingerprint else {
                throw ProductDeviceSessionError.credentialsUnavailable
            }
        } catch let error as ProductDeviceSessionError {
            throw error
        } catch {
            throw ProductDeviceSessionError.credentialsUnavailable
        }

        do {
            return try PairingCredentials(
                pairingID: record.pairingID,
                pairingKey: record.pairingKey,
                deviceIdentityFingerprint: record.deviceIdentityFingerprint
            )
        } catch {
            throw ProductDeviceSessionError.credentialsUnavailable
        }
    }
}
