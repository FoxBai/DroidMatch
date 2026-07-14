import Foundation

/// Owns one anonymous device lease and at most one product TCP client.
///
/// Hello-only probing is deliberately a separate fresh connection: the
/// fingerprint in that response is only a credential selector. Trust is granted
/// only after the second connection proves the matching pairing key, or after a
/// visible SAS pairing ceremony. Every operation carries a generation so actor
/// reentrancy cannot publish a result after disconnect or a newer operation.
public actor ProductDeviceSessionCoordinator: ProductDeviceSessionCoordinating {
    typealias IdentityProbe = @Sendable (DeviceConnectionLease) async throws -> Data
    typealias SessionFactory = @Sendable (
        DeviceConnectionLease,
        PairingCredentials
    ) async throws -> any ProductSessionClient
    typealias PairingFactory = @Sendable (
        DeviceConnectionLease,
        any PairingCredentialStoring
    ) async throws -> any ProductPairingClient

    private let connectionPreparer: any DeviceConnectionPreparing
    private let credentialStore: any PairingCredentialStoring
    private let identityProbe: IdentityProbe
    private let sessionFactory: SessionFactory
    private let pairingFactory: PairingFactory
    private let transferPersistenceDirectoryURL: URL?
    private let keepaliveInterval: Duration
    private let localFileAccessProviderFactory:
        @Sendable (LocalFileAccessOwnerID) -> any LocalFileAccessProviding

    private var generation: UInt64 = 0
    private var lease: DeviceConnectionLease?
    private var selectedFingerprint: Data?
    private var sessionClient: (any ProductSessionClient)?
    private var pairingClient: (any ProductPairingClient)?
    private var readyInfo: ProductDeviceSessionInfo?
    private var transferSchedulerLifecycle = ProductTransferSchedulerLifecycle()
    private var keepaliveTask: Task<Void, Never>?
    private var sessionEventChannel: ProductDeviceSessionEventChannel?

    public init(
        connectionPreparer: any DeviceConnectionPreparing,
        credentialStore: any PairingCredentialStoring = KeychainPairingCredentialStore(),
        transferPersistenceDirectoryURL: URL? = nil,
        localFileAccessProviderFactory: @escaping @Sendable (
            LocalFileAccessOwnerID
        ) -> any LocalFileAccessProviding = { _ in UnrestrictedLocalFileAccessProvider() }
    ) {
        self.connectionPreparer = connectionPreparer
        self.credentialStore = credentialStore
        self.transferPersistenceDirectoryURL = transferPersistenceDirectoryURL
        keepaliveInterval = .seconds(10)
        self.localFileAccessProviderFactory = localFileAccessProviderFactory
        identityProbe = { lease in
            let result = try await HandshakeSmokeClient(
                clientName: "DroidMatch Mac",
                clientVersion: "0.1.0-m1",
                requestedCapabilities: []
            ).run(host: lease.host, port: lease.port)
            switch result.authenticationState {
            case .correlated:
                // A nonce-only response is the debug harness contract. It proves
                // transport reachability, but it is not a product trust boundary.
                // 中文：仅 nonce 的响应只能证明链路可达，不能作为产品安全会话。
                throw ProductDeviceSessionError.secureEndpointRequired
            case .pairingRequired:
                guard result.deviceIdentityFingerprint.count == PairingAuthenticator.digestLength else {
                    throw ProductDeviceSessionError.identityUnavailable
                }
                return result.deviceIdentityFingerprint
            case .required, .authenticated, .unspecified, .UNRECOGNIZED:
                throw ProductDeviceSessionError.identityUnavailable
            }
        }
        sessionFactory = { lease, credentials in
            let session = try await AsyncFramedTcpSession.connect(
                host: lease.host,
                port: lease.port,
                timeoutSeconds: 10
            )
            return AsyncRpcControlClient(
                session: session,
                credentials: credentials,
                requestedCapabilities: HandshakeSmokeClient.fullM1Capabilities,
                requestTimeoutSeconds: 10
            )
        }
        pairingFactory = { lease, store in
            let session = try await AsyncFramedTcpSession.connect(
                host: lease.host,
                port: lease.port,
                timeoutSeconds: 130
            )
            return AsyncPairingClient(session: session, credentialStore: store)
        }
    }

    init(
        connectionPreparer: any DeviceConnectionPreparing,
        credentialStore: any PairingCredentialStoring,
        identityProbe: @escaping IdentityProbe,
        sessionFactory: @escaping SessionFactory,
        pairingFactory: @escaping PairingFactory,
        transferPersistenceDirectoryURL: URL? = nil,
        keepaliveInterval: Duration = .seconds(10),
        localFileAccessProviderFactory: @escaping @Sendable (
            LocalFileAccessOwnerID
        ) -> any LocalFileAccessProviding = { _ in UnrestrictedLocalFileAccessProvider() }
    ) {
        self.connectionPreparer = connectionPreparer
        self.credentialStore = credentialStore
        self.identityProbe = identityProbe
        self.sessionFactory = sessionFactory
        self.pairingFactory = pairingFactory
        self.transferPersistenceDirectoryURL = transferPersistenceDirectoryURL
        self.keepaliveInterval = keepaliveInterval
        self.localFileAccessProviderFactory = localFileAccessProviderFactory
    }

    public func connect(to deviceID: UUID) async throws -> ProductDeviceConnectionOutcome {
        generation &+= 1
        let operationGeneration = generation
        await resetSession()
        try requireCurrent(operationGeneration)

        let preparedLease: DeviceConnectionLease
        do {
            preparedLease = try await connectionPreparer.prepareConnection(to: deviceID)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as DeviceConnectionPreparationError {
            throw error
        } catch {
            throw ProductDeviceSessionError.connectionUnavailable
        }
        guard generation == operationGeneration else {
            await connectionPreparer.releaseConnection(preparedLease)
            throw CancellationError()
        }
        lease = preparedLease

        do {
            let fingerprint = try await identityProbe(preparedLease)
            try requireCurrent(operationGeneration)
            guard fingerprint.count == PairingAuthenticator.digestLength else {
                throw ProductDeviceSessionError.identityUnavailable
            }
            selectedFingerprint = fingerprint

            guard let metadata = try credentialStore.list().first(where: {
                $0.deviceIdentityFingerprint == fingerprint
            }) else {
                return .pairingRequired
            }
            let record = try credentialStore.load(pairingID: metadata.pairingID)
            let info = try await authenticate(
                record: record,
                lease: preparedLease,
                generation: operationGeneration
            )
            return .ready(info)
        } catch {
            await cleanupIfCurrent(operationGeneration)
            throw Self.normalized(error)
        }
    }

    public func pair(
        clientDisplayName: String = "DroidMatch Mac",
        approve: @escaping @Sendable (PairingPresentation) async throws -> Bool
    ) async throws -> ProductDeviceSessionInfo {
        guard let preparedLease = lease,
              let expectedFingerprint = selectedFingerprint else {
            throw ProductDeviceSessionError.noPreparedDevice
        }
        guard sessionClient == nil, pairingClient == nil, readyInfo == nil else {
            throw ProductDeviceSessionError.pairingNotRequired
        }

        generation &+= 1
        let operationGeneration = generation
        var newPairingID: Data?
        do {
            let client = try await pairingFactory(preparedLease, credentialStore)
            do {
                try requireCurrent(operationGeneration)
            } catch {
                await client.close()
                throw error
            }
            pairingClient = client
            let metadata = try await client.pair(
                clientDisplayName: clientDisplayName,
                approve: approve
            )
            newPairingID = metadata.pairingID
            try requireCurrent(operationGeneration)
            pairingClient = nil
            guard metadata.deviceIdentityFingerprint == expectedFingerprint else {
                try? credentialStore.revoke(pairingID: metadata.pairingID)
                throw ProductDeviceSessionError.identityChanged
            }
            let record = try credentialStore.load(pairingID: metadata.pairingID)
            return try await authenticate(
                record: record,
                lease: preparedLease,
                generation: operationGeneration
            )
        } catch {
            if case ProductDeviceSessionError.identityChanged = error,
               let newPairingID {
                try? credentialStore.revoke(pairingID: newPairingID)
            }
            await cleanupIfCurrent(operationGeneration)
            throw Self.normalized(error)
        }
    }

    public func directoryListingClient() throws -> any DirectoryBrowserClient {
        guard readyInfo != nil, let sessionClient else {
            throw ProductDeviceSessionError.noPreparedDevice
        }
        return sessionClient
    }

    /// Builds the process-local product queue without exposing the forward or
    /// pairing credential to Presentation. Every coordinator attempt receives a
    /// fresh authenticated RPC client because each transfer owns one reader.
    public func transferScheduler() async throws -> AsyncTransferScheduler {
        let operationGeneration = generation
        guard let readyInfo,
              readyInfo.grantedCapabilities.contains(.fileRead),
              readyInfo.grantedCapabilities.contains(.resumableTransfer),
              let lease,
              let selectedFingerprint,
              let localFileAccessOwnerID = LocalFileAccessOwnerID(
                  authenticatedDeviceFingerprint: selectedFingerprint
              ) else {
            throw ProductDeviceSessionError.noPreparedDevice
        }
        if let build = transferSchedulerLifecycle.build(for: operationGeneration) {
            return try await awaitTransferSchedulerBuild(build)
        }
        if let scheduler = transferSchedulerLifecycle.scheduler {
            return scheduler
        }

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

        let credentials: PairingCredentials
        do {
            credentials = try PairingCredentials(
                pairingID: record.pairingID,
                pairingKey: record.pairingKey,
                deviceIdentityFingerprint: record.deviceIdentityFingerprint
            )
        } catch {
            throw ProductDeviceSessionError.credentialsUnavailable
        }

        let persistenceStore = try transferPersistenceURL(for: selectedFingerprint).map {
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
        let accessProvider = localFileAccessProviderFactory(localFileAccessOwnerID)
        let downloadExecutor: AsyncDownloadJobExecutor = { request, retry, progress in
            let access = try await accessProvider.acquireAccess(to: request.destinationURL)
            defer { access.release() }
            return try await downloadCoordinator.download(
                request,
                onRetry: retry,
                onProgress: progress
            )
        }
        let uploadExecutor: AsyncUploadJobExecutor = { request, retry, progress in
            let access = try await accessProvider.acquireAccess(to: request.sourceURL)
            defer { access.release() }
            return try await uploadCoordinator.upload(
                request,
                onRetry: retry,
                onProgress: progress
            )
        }
        guard let persistenceStore else {
            let scheduler = AsyncTransferScheduler(
                maxConcurrentJobs: 2,
                downloadExecutor: downloadExecutor,
                uploadExecutor: uploadExecutor,
                localFileAccessOwnerID: localFileAccessOwnerID
            )
            try transferSchedulerLifecycle.installTransient(
                gate: gate,
                scheduler: scheduler
            )
            return scheduler
        }

        let buildID = UUID()
        let buildTask = Task { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.buildPersistentTransferScheduler(
                buildID: buildID,
                operationGeneration: operationGeneration,
                gate: gate,
                accessProvider: accessProvider,
                persistenceStore: persistenceStore,
                localFileAccessOwnerID: localFileAccessOwnerID,
                downloadExecutor: downloadExecutor,
                uploadExecutor: uploadExecutor
            )
        }
        let build = try transferSchedulerLifecycle.beginBuild(
            id: buildID,
            generation: operationGeneration,
            task: buildTask
        )
        return try await awaitTransferSchedulerBuild(build)
    }

    private func buildPersistentTransferScheduler(
        buildID: UUID,
        operationGeneration: UInt64,
        gate: ProductTransferSessionGate,
        accessProvider: any LocalFileAccessProviding,
        persistenceStore: TransferQueuePersistenceStore,
        localFileAccessOwnerID: LocalFileAccessOwnerID,
        downloadExecutor: @escaping AsyncDownloadJobExecutor,
        uploadExecutor: @escaping AsyncUploadJobExecutor
    ) async throws -> AsyncTransferScheduler {
        do {
            try requireTransferSchedulerBuild(buildID, generation: operationGeneration)
            try transferSchedulerLifecycle.publishGate(gate, buildID: buildID)
            return try await accessProvider.withTransferExecutionPreparation {
                let scheduler = try await AsyncTransferScheduler.restoring(
                    maxConcurrentJobs: 2,
                    persistenceStore: persistenceStore,
                    downloadExecutor: downloadExecutor,
                    uploadExecutor: uploadExecutor,
                    localFileAccessOwnerID: localFileAccessOwnerID,
                    startQueuedJobs: false
                )
                do {
                    try await self.registerTransferScheduler(
                        scheduler,
                        buildID: buildID,
                        generation: operationGeneration
                    )
                    let persisted = await scheduler.retryPersistence(startQueuedJobs: false)
                    try await self.requireTransferSchedulerBuild(
                        buildID,
                        generation: operationGeneration
                    )
                    guard persisted else { return scheduler }
                    let targets = await scheduler.requiredLocalFileAccessURLs()
                    let isReady = await accessProvider.isReadyForTransferExecution(
                        targetURLs: targets
                    )
                    try await self.requireTransferSchedulerBuild(
                        buildID,
                        generation: operationGeneration
                    )
                    guard isReady else { return scheduler }
                    _ = await scheduler.activateExecution()
                    try await self.requireTransferSchedulerBuild(
                        buildID,
                        generation: operationGeneration
                    )
                    return scheduler
                } catch {
                    await self.discardTransferSchedulerBuild(
                        scheduler: scheduler,
                        gate: gate,
                        buildID: buildID
                    )
                    throw error
                }
            }
        } catch {
            transferSchedulerLifecycle.clearGateIfOwned(gate, buildID: buildID)
            await gate.invalidate()
            throw error
        }
    }

    private func registerTransferScheduler(
        _ scheduler: AsyncTransferScheduler,
        buildID: UUID,
        generation operationGeneration: UInt64
    ) throws {
        try requireTransferSchedulerBuild(buildID, generation: operationGeneration)
        try transferSchedulerLifecycle.publishScheduler(scheduler, buildID: buildID)
    }

    private func requireTransferSchedulerBuild(
        _ buildID: UUID,
        generation operationGeneration: UInt64
    ) throws {
        try requireCurrent(operationGeneration)
        try transferSchedulerLifecycle.requireBuild(id: buildID)
    }

    private func discardTransferSchedulerBuild(
        scheduler: AsyncTransferScheduler,
        gate: ProductTransferSessionGate,
        buildID: UUID
    ) async {
        transferSchedulerLifecycle.discardPublishedResources(
            scheduler: scheduler,
            gate: gate,
            buildID: buildID
        )
        await gate.invalidate()
        await scheduler.suspendForSessionEnd()
    }

    private func awaitTransferSchedulerBuild(
        _ build: ProductTransferSchedulerLifecycle.Build
    ) async throws -> AsyncTransferScheduler {
        do {
            let scheduler = try await build.task.value
            try Task.checkCancellation()
            try requireCurrent(build.generation)
            try transferSchedulerLifecycle.requirePublished(scheduler)
            transferSchedulerLifecycle.clearBuild(id: build.id)
            return scheduler
        } catch {
            transferSchedulerLifecycle.clearBuild(id: build.id)
            throw error
        }
    }

    /// Keeps recovery state bound to the authenticated Android identity. A
    /// queue created for one phone must never replay against another phone just
    /// because both were connected through the same local ADB endpoint.
    private func transferPersistenceURL(for fingerprint: Data) -> URL? {
        Self.transferPersistenceURL(
            directory: transferPersistenceDirectoryURL,
            fingerprint: fingerprint
        )
    }

    static func transferPersistenceURL(directory: URL?, fingerprint: Data) -> URL? {
        guard let directory,
              directory.isFileURL,
              !directory.path.isEmpty else {
            return nil
        }
        let identity = fingerprint.map { String(format: "%02x", $0) }.joined()
        guard !identity.isEmpty else { return nil }
        return directory.appendingPathComponent("queue-\(identity).json", isDirectory: false)
    }

    public func diagnosticsSnapshot() async throws -> ProductDeviceDiagnosticsSnapshot {
        guard readyInfo != nil, let sessionClient else {
            throw ProductDeviceDiagnosticsError.sessionUnavailable
        }
        do {
            return try await sessionClient.productDiagnosticsSnapshot()
        } catch let error as ProductDeviceDiagnosticsError {
            throw error
        } catch let error as RpcControlClientError {
            if case let .remoteError(remote) = error,
               remote.code == .unsupportedCapability {
                throw ProductDeviceDiagnosticsError.unsupported
            }
            throw ProductDeviceDiagnosticsError.unavailable
        } catch is AsyncRpcControlClientStateError {
            throw ProductDeviceDiagnosticsError.sessionUnavailable
        } catch {
            throw ProductDeviceDiagnosticsError.unavailable
        }
    }

    public func sessionInvalidationEvents() async throws -> AsyncStream<ProductDeviceSessionEvent> {
        guard let sessionEventChannel else {
            throw ProductDeviceSessionError.noPreparedDevice
        }
        return sessionEventChannel.stream()
    }

    public func disconnect() async {
        generation &+= 1
        await resetSession()
    }

    private func authenticate(
        record: PairingCredentialRecord,
        lease: DeviceConnectionLease,
        generation operationGeneration: UInt64
    ) async throws -> ProductDeviceSessionInfo {
        guard record.deviceIdentityFingerprint == selectedFingerprint else {
            throw ProductDeviceSessionError.authenticationFailed
        }
        let credentials: PairingCredentials
        do {
            credentials = try PairingCredentials(
                pairingID: record.pairingID,
                pairingKey: record.pairingKey,
                deviceIdentityFingerprint: record.deviceIdentityFingerprint
            )
        } catch {
            throw ProductDeviceSessionError.credentialsUnavailable
        }
        let client = try await sessionFactory(lease, credentials)
        do {
            try requireCurrent(operationGeneration)
        } catch {
            await client.close()
            throw error
        }
        sessionClient = client
        let handshake = try await client.handshake()
        try requireCurrent(operationGeneration)
        guard handshake.authenticationState == .authenticated,
              handshake.deviceIdentityFingerprint == selectedFingerprint else {
            throw ProductDeviceSessionError.authenticationFailed
        }
        let info = ProductDeviceSessionInfo(
            deviceID: lease.deviceID,
            displayName: handshake.serverName.isEmpty ? record.displayName : handshake.serverName,
            grantedCapabilities: handshake.grantedCapabilities
        )
        readyInfo = info

        var usedRecord = record
        usedRecord.lastUsedAt = Date()
        try credentialStore.save(usedRecord)
        sessionEventChannel = ProductDeviceSessionEventChannel()
        startKeepalive(generation: operationGeneration)
        return info
    }

    /// Keeps the authenticated control/browser session inside Android's idle
    /// boundary while a user reads or navigates the native UI. Transfers use
    /// fresh clients, but terminal session teardown still suspends their queue.
    private func startKeepalive(generation operationGeneration: UInt64) {
        keepaliveTask?.cancel()
        let interval = keepaliveInterval
        keepaliveTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                    guard !Task.isCancelled, let self else { return }
                    try await self.sendKeepalive(generation: operationGeneration)
                } catch is CancellationError {
                    return
                } catch {
                    guard let self else { return }
                    await self.handleKeepaliveFailure(generation: operationGeneration)
                    return
                }
            }
        }
    }

    private func sendKeepalive(generation operationGeneration: UInt64) async throws {
        try requireCurrent(operationGeneration)
        guard readyInfo != nil, let sessionClient else {
            throw ProductDeviceSessionError.connectionUnavailable
        }
        let value = Int64(ProcessInfo.processInfo.systemUptime * 1_000)
        let response = try await sessionClient.heartbeat(monotonicMillis: value)
        guard response.monotonicMillis == value else {
            throw ProductDeviceSessionError.connectionUnavailable
        }
        try requireCurrent(operationGeneration)
    }

    private func detachResources() -> ProductDeviceSessionDetachedResources {
        let transferResources = transferSchedulerLifecycle.detach()
        let resources = ProductDeviceSessionDetachedResources(
            lease: lease,
            sessionClient: sessionClient,
            pairingClient: pairingClient,
            transferGate: transferResources.gate,
            transferScheduler: transferResources.scheduler,
            transferSchedulerBuildTask: transferResources.buildTask,
            keepaliveTask: keepaliveTask
        )
        lease = nil
        selectedFingerprint = nil
        sessionClient = nil
        pairingClient = nil
        readyInfo = nil
        keepaliveTask = nil
        return resources
    }

    private func cleanupIfCurrent(_ operationGeneration: UInt64) async {
        guard generation == operationGeneration else { return }
        await resetSession()
    }

    private func resetSession() async {
        let eventChannel = sessionEventChannel
        sessionEventChannel = nil
        let resources = detachResources()
        eventChannel?.finish()
        await resources.release(using: connectionPreparer)
    }

    private func handleKeepaliveFailure(generation operationGeneration: UInt64) async {
        guard generation == operationGeneration,
              let eventChannel = sessionEventChannel else { return }
        let resources = detachResources()
        await resources.release(using: connectionPreparer)
        guard generation == operationGeneration,
              sessionEventChannel === eventChannel else { return }
        eventChannel.sendTerminal(.connectionUnavailable)
    }

    private func requireCurrent(_ operationGeneration: UInt64) throws {
        try Task.checkCancellation()
        guard generation == operationGeneration else {
            throw CancellationError()
        }
    }

    private static func normalized(_ error: Error) -> Error {
        if error is CancellationError
            || error is DeviceConnectionPreparationError
            || error is ProductDeviceSessionError {
            return error
        }
        if error is PairingCredentialStoreError {
            return ProductDeviceSessionError.credentialsUnavailable
        }
        if case AsyncPairingClientError.userRejected = error {
            return ProductDeviceSessionError.pairingRejected
        }
        if error is AsyncRpcAuthenticationError {
            return ProductDeviceSessionError.authenticationFailed
        }
        return ProductDeviceSessionError.connectionUnavailable
    }
}
