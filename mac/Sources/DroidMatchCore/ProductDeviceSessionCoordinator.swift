import Foundation

public enum ProductDeviceSessionError: Error, Sendable, Equatable {
    case noPreparedDevice
    case pairingNotRequired
    case identityUnavailable
    case identityChanged
    case pairingRejected
    case credentialsUnavailable
    case authenticationFailed
    case connectionUnavailable
}

public struct ProductDeviceSessionInfo: Sendable, Equatable {
    public let deviceID: UUID
    public let displayName: String
    public let grantedCapabilities: [Droidmatch_V1_Capability]

    public init(
        deviceID: UUID,
        displayName: String,
        grantedCapabilities: [Droidmatch_V1_Capability]
    ) {
        self.deviceID = deviceID
        self.displayName = displayName
        self.grantedCapabilities = grantedCapabilities
    }
}

public enum ProductDeviceConnectionOutcome: Sendable, Equatable {
    case ready(ProductDeviceSessionInfo)
    case pairingRequired
}

public protocol ProductDeviceSessionCoordinating: ProductDeviceDiagnosticsLoading {
    func connect(to deviceID: UUID) async throws -> ProductDeviceConnectionOutcome
    func pair(
        clientDisplayName: String,
        approve: @escaping @Sendable (PairingPresentation) async throws -> Bool
    ) async throws -> ProductDeviceSessionInfo
    func directoryListingClient() async throws -> any DirectoryListingClient
    func transferScheduler() async throws -> AsyncTransferScheduler
    func disconnect() async
}

/// Narrow client surface owned by the product coordinator.
///
/// Keeping this protocol separate from the concrete RPC actor makes resource
/// ownership, stale-operation rejection, and credential selection testable
/// without a live socket or Keychain.
public protocol ProductSessionClient: DirectoryListingClient, ProductDiagnosticsClient {
    func handshake() async throws -> HandshakeSmokeResult
    func close() async
}

extension AsyncRpcControlClient: ProductSessionClient {}

public protocol ProductPairingClient: Sendable {
    func pair(
        clientDisplayName: String,
        approve: @escaping @Sendable (PairingPresentation) async throws -> Bool
    ) async throws -> PairingCredentialMetadata
    func close() async
}

extension AsyncPairingClient: ProductPairingClient {}

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

    private var generation: UInt64 = 0
    private var lease: DeviceConnectionLease?
    private var selectedFingerprint: Data?
    private var sessionClient: (any ProductSessionClient)?
    private var pairingClient: (any ProductPairingClient)?
    private var readyInfo: ProductDeviceSessionInfo?
    private var transferGate: ProductTransferSessionGate?
    private var activeTransferScheduler: AsyncTransferScheduler?

    public init(
        connectionPreparer: any DeviceConnectionPreparing,
        credentialStore: any PairingCredentialStoring = KeychainPairingCredentialStore(),
        transferPersistenceDirectoryURL: URL? = nil
    ) {
        self.connectionPreparer = connectionPreparer
        self.credentialStore = credentialStore
        self.transferPersistenceDirectoryURL = transferPersistenceDirectoryURL
        identityProbe = { lease in
            let result = try await HandshakeSmokeClient(
                clientName: "DroidMatch Mac",
                clientVersion: "0.1.0-m1",
                requestedCapabilities: []
            ).run(host: lease.host, port: lease.port)
            guard result.authenticationState == .pairingRequired,
                  result.deviceIdentityFingerprint.count == PairingAuthenticator.digestLength else {
                throw ProductDeviceSessionError.identityUnavailable
            }
            return result.deviceIdentityFingerprint
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
        transferPersistenceDirectoryURL: URL? = nil
    ) {
        self.connectionPreparer = connectionPreparer
        self.credentialStore = credentialStore
        self.identityProbe = identityProbe
        self.sessionFactory = sessionFactory
        self.pairingFactory = pairingFactory
        self.transferPersistenceDirectoryURL = transferPersistenceDirectoryURL
    }

    public func connect(to deviceID: UUID) async throws -> ProductDeviceConnectionOutcome {
        generation &+= 1
        let operationGeneration = generation
        await releaseDetachedResources(detachResources())
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

    public func directoryListingClient() throws -> any DirectoryListingClient {
        guard readyInfo != nil, let sessionClient else {
            throw ProductDeviceSessionError.noPreparedDevice
        }
        return sessionClient
    }

    /// Builds the process-local product queue without exposing the forward or
    /// pairing credential to Presentation. Every coordinator attempt receives a
    /// fresh authenticated RPC client because each transfer owns one reader.
    public func transferScheduler() async throws -> AsyncTransferScheduler {
        guard let readyInfo,
              readyInfo.grantedCapabilities.contains(.fileRead),
              readyInfo.grantedCapabilities.contains(.resumableTransfer),
              let lease,
              let selectedFingerprint else {
            throw ProductDeviceSessionError.noPreparedDevice
        }
        if let activeTransferScheduler {
            return activeTransferScheduler
        }

        let record: PairingCredentialRecord
        do {
            guard let metadata = try credentialStore.list().first(where: {
                $0.deviceIdentityFingerprint == selectedFingerprint
            }) else {
                throw ProductDeviceSessionError.credentialsUnavailable
            }
            record = try credentialStore.load(pairingID: metadata.pairingID)
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

        let gate = ProductTransferSessionGate(
            lease: lease,
            credentials: credentials
        )
        let clientFactory: AsyncRpcControlClientFactory = { attemptIndex in
            try await gate.makeClient(attemptIndex: attemptIndex)
        }
        let downloadCoordinator = AsyncDownloadCoordinator(clientFactory: clientFactory)
        let uploadCoordinator = AsyncUploadCoordinator(clientFactory: clientFactory)
        let scheduler: AsyncTransferScheduler
        if let persistenceURL = transferPersistenceURL(for: selectedFingerprint) {
            let store = try TransferQueuePersistenceStore(fileURL: persistenceURL)
            scheduler = try await AsyncTransferScheduler.restoring(
                downloadCoordinator: downloadCoordinator,
                uploadCoordinator: uploadCoordinator,
                persistenceStore: store,
                maxConcurrentJobs: 2
            )
        } else {
            scheduler = AsyncTransferScheduler(
                downloadCoordinator: downloadCoordinator,
                uploadCoordinator: uploadCoordinator,
                maxConcurrentJobs: 2
            )
        }
        transferGate = gate
        activeTransferScheduler = scheduler
        return scheduler
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

    public func disconnect() async {
        generation &+= 1
        await releaseDetachedResources(detachResources())
    }

    private func authenticate(
        record: PairingCredentialRecord,
        lease: DeviceConnectionLease,
        generation operationGeneration: UInt64
    ) async throws -> ProductDeviceSessionInfo {
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
        return info
    }

    private struct DetachedResources {
        let lease: DeviceConnectionLease?
        let sessionClient: (any ProductSessionClient)?
        let pairingClient: (any ProductPairingClient)?
        let transferGate: ProductTransferSessionGate?
        let transferScheduler: AsyncTransferScheduler?
    }

    private func detachResources() -> DetachedResources {
        let resources = DetachedResources(
            lease: lease,
            sessionClient: sessionClient,
            pairingClient: pairingClient,
            transferGate: transferGate,
            transferScheduler: activeTransferScheduler
        )
        lease = nil
        selectedFingerprint = nil
        sessionClient = nil
        pairingClient = nil
        readyInfo = nil
        transferGate = nil
        activeTransferScheduler = nil
        return resources
    }

    private func releaseDetachedResources(_ resources: DetachedResources) async {
        // Invalidation happens before the first suspension that could let an
        // in-flight retry request another client. Queue shutdown then closes all
        // already-created transfer clients before the forward is released.
        await resources.transferGate?.invalidate()
        await resources.transferScheduler?.suspendForSessionEnd()
        await resources.pairingClient?.close()
        await resources.sessionClient?.close()
        if let lease = resources.lease {
            await connectionPreparer.releaseConnection(lease)
        }
    }

    private func cleanupIfCurrent(_ operationGeneration: UInt64) async {
        guard generation == operationGeneration else { return }
        await releaseDetachedResources(detachResources())
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

/// Session-scoped factory gate captured by transfer coordinators.
///
/// It owns the only copy of the forward endpoint and product credentials used by
/// retry clients. Once invalidated it never reopens, so an old queue cannot attach
/// itself to a later device session even if a local port number is recycled.
private actor ProductTransferSessionGate {
    private let lease: DeviceConnectionLease
    private let credentials: PairingCredentials
    private var isActive = true

    init(lease: DeviceConnectionLease, credentials: PairingCredentials) {
        self.lease = lease
        self.credentials = credentials
    }

    func makeClient(attemptIndex: Int) async throws -> AsyncRpcControlClient {
        _ = attemptIndex // Attempt identity is intentionally not security state.
        guard isActive else { throw CancellationError() }
        let session = try await AsyncFramedTcpSession.connect(
            host: lease.host,
            port: lease.port,
            timeoutSeconds: 10
        )
        guard isActive else {
            await session.close()
            throw CancellationError()
        }
        return AsyncRpcControlClient(
            session: session,
            credentials: credentials,
            requestedCapabilities: HandshakeSmokeClient.fullM1Capabilities,
            requestTimeoutSeconds: 10
        )
    }

    func invalidate() {
        isActive = false
    }
}
