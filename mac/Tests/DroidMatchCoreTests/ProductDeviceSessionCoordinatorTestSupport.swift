@_spi(DroidMatchAppSupport) @testable import DroidMatchCore
import Foundation

// Shared probes keep transport, trust, pairing, and local-access mechanics out of test narratives.
// 中文：共享 probe 将 transport、trust、pairing 与本地授权机制从行为测试叙事中分离。
actor SessionConnectionPreparerProbe: DeviceConnectionPreparing {
    private let deviceID: UUID
    private let port: Int
    private var releases = 0

    init(deviceID: UUID, port: Int = 45_600) {
        self.deviceID = deviceID
        self.port = port
    }

    func prepareConnection(to deviceID: UUID) throws -> DeviceConnectionLease {
        guard deviceID == self.deviceID else {
            throw DeviceConnectionPreparationError.deviceUnavailable
        }
        return DeviceConnectionLease(deviceID: deviceID, host: "127.0.0.1", port: port)
    }

    func releaseConnection(_ lease: DeviceConnectionLease) {
        releases += 1
    }

    func releaseCount() -> Int { releases }
}

private enum SessionLocalAccessProbeError: Error {
    case unavailable
}

actor SessionLocalAccessProbe: LocalFileAccessProviding {
    private let ready: Bool
    private let coveredTargetPaths: Set<String>
    private var acquisitions = 0

    init(ready: Bool, coveredTargetURLs: Set<URL>) {
        self.ready = ready
        coveredTargetPaths = Set(coveredTargetURLs.map { $0.standardizedFileURL.path })
    }

    func isReadyForTransferExecution() async -> Bool { ready }

    func isReadyForTransferExecution(targetURLs: Set<URL>) async -> Bool {
        ready && targetURLs.allSatisfy {
            coveredTargetPaths.contains($0.standardizedFileURL.path)
        }
    }

    func acquireAccess(to url: URL) async throws -> any LocalFileAccessLease {
        _ = url
        acquisitions += 1
        throw SessionLocalAccessProbeError.unavailable
    }

    func acquisitionCount() -> Int { acquisitions }
}

final class ScopedRestoreLocalAccessProbe:
    LocalFileAccessProviding,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let directory: URL
    private var acquisitions = 0
    private var releases = 0

    init(directory: URL) {
        self.directory = directory
    }

    func isReadyForTransferExecution() async -> Bool { true }

    func isReadyForTransferExecution(targetURLs: Set<URL>) async -> Bool {
        !targetURLs.isEmpty
    }

    func acquireAccess(to url: URL) async throws -> any LocalFileAccessLease {
        _ = url
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: directory.path
        )
        lock.withLock { acquisitions += 1 }
        return ScopedRestoreAccessLease(directory: directory) { [weak self] in
            self?.didRelease()
        }
    }

    func acquisitionCount() -> Int { lock.withLock { acquisitions } }
    func releaseCount() -> Int { lock.withLock { releases } }

    private func didRelease() {
        lock.withLock { releases += 1 }
    }
}

private final class ScopedRestoreAccessLease: LocalFileAccessLease, @unchecked Sendable {
    private let lock = NSLock()
    private var directory: URL?
    private var onRelease: (@Sendable () -> Void)?

    init(directory: URL, onRelease: @escaping @Sendable () -> Void) {
        self.directory = directory
        self.onRelease = onRelease
    }

    func release() {
        lock.lock()
        let directory = directory
        let onRelease = onRelease
        self.directory = nil
        self.onRelease = nil
        lock.unlock()
        guard let directory else { return }
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o000)],
            ofItemAtPath: directory.path
        )
        onRelease?()
    }

    deinit { release() }
}

actor ManifestRepairingLocalAccessProbe: LocalFileAccessProviding {
    private let manifestURL: URL
    private let repairedManifest: Data
    private var targetReadinessCalls = 0
    private var acquisitions = 0

    init(manifestURL: URL, repairedManifest: Data) {
        self.manifestURL = manifestURL
        self.repairedManifest = repairedManifest
    }

    func isReadyForTransferExecution() async -> Bool { true }

    func isReadyForTransferExecution(targetURLs: Set<URL>) async -> Bool {
        _ = targetURLs
        targetReadinessCalls += 1
        try? repairedManifest.write(to: manifestURL)
        return true
    }

    func acquireAccess(to url: URL) async throws -> any LocalFileAccessLease {
        _ = url
        acquisitions += 1
        throw SessionLocalAccessProbeError.unavailable
    }

    func targetReadinessCount() -> Int { targetReadinessCalls }
    func acquisitionCount() -> Int { acquisitions }
}

struct DefaultReadyLocalAccessProbe: LocalFileAccessProviding {
    func acquireAccess(to url: URL) async throws -> any LocalFileAccessLease {
        _ = url
        throw SessionLocalAccessProbeError.unavailable
    }
}

final class LocalFileAccessProviderFactoryProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var owners: [LocalFileAccessOwnerID] = []

    func make(ownerID: LocalFileAccessOwnerID) -> any LocalFileAccessProviding {
        lock.withLock { owners.append(ownerID) }
        return UnrestrictedLocalFileAccessProvider()
    }

    func ownerIDs() -> [LocalFileAccessOwnerID] {
        lock.withLock { owners }
    }
}

final class SessionCredentialStoreProbe: PairingCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [Data: PairingCredentialRecord]
    private let listedMetadata: [PairingCredentialMetadata]?
    private var secretReads = 0
    private var saveWrites = 0

    init(
        records: [PairingCredentialRecord] = [],
        listedMetadata: [PairingCredentialMetadata]? = nil
    ) {
        self.records = Dictionary(uniqueKeysWithValues: records.map { ($0.pairingID, $0) })
        self.listedMetadata = listedMetadata
    }

    func save(_ record: PairingCredentialRecord) throws {
        lock.lock()
        saveWrites += 1
        records[record.pairingID] = record
        lock.unlock()
    }

    func insertNew(_ record: PairingCredentialRecord) throws {
        lock.lock()
        defer { lock.unlock() }
        guard records[record.pairingID] == nil else {
            throw PairingCredentialStoreError.duplicatePairingID
        }
        saveWrites += 1
        records[record.pairingID] = record
    }

    func load(pairingID: Data) throws -> PairingCredentialRecord {
        lock.lock()
        defer { lock.unlock() }
        secretReads += 1
        guard let record = records[pairingID] else {
            throw PairingCredentialStoreError.notFound
        }
        return record
    }

    func list() throws -> [PairingCredentialMetadata] {
        lock.lock()
        defer { lock.unlock() }
        if let listedMetadata { return listedMetadata }
        return records.values.map(\.metadata).sorted { $0.lastUsedAt > $1.lastUsedAt }
    }

    func revoke(pairingID: Data) throws {
        lock.lock()
        records.removeValue(forKey: pairingID)
        lock.unlock()
    }

    func secretReadCount() -> Int {
        lock.withLock { secretReads }
    }

    func saveWriteCount() -> Int {
        lock.withLock { saveWrites }
    }

    func replaceRecords(_ replacements: [PairingCredentialRecord]) {
        lock.withLock {
            records = Dictionary(uniqueKeysWithValues: replacements.map {
                ($0.pairingID, $0)
            })
        }
    }
}

actor SessionClientFactoryProbe {
    private let fingerprint: Data
    private let handshakeError: (any Error & Sendable)?
    private let heartbeatError: (any Error & Sendable)?
    private let heartbeatResponseOffset: Int64
    private var clients: [SessionClientProbe] = []
    private var pairingIDs: [Data] = []

    init(
        fingerprint: Data,
        handshakeError: (any Error & Sendable)? = nil,
        heartbeatError: (any Error & Sendable)? = nil,
        heartbeatResponseOffset: Int64 = 0
    ) {
        self.fingerprint = fingerprint
        self.handshakeError = handshakeError
        self.heartbeatError = heartbeatError
        self.heartbeatResponseOffset = heartbeatResponseOffset
    }

    func make(
        lease: DeviceConnectionLease,
        credentials: PairingCredentials
    ) -> any ProductSessionClient {
        pairingIDs.append(credentials.pairingID)
        let client = SessionClientProbe(
            handshake: HandshakeSmokeResult(
                requestID: 1,
                serverName: "Test Android",
                serverVersion: "test",
                protocolMajor: 1,
                protocolMinor: 0,
                transport: .adb,
                grantedCapabilities: [
                    .fileList,
                    .fileRead,
                    .resumableTransfer,
                    .diagnostics,
                ],
                sessionNonce: Data(repeating: 1, count: 32),
                serverNonce: Data(repeating: 2, count: 32),
                deviceIdentityFingerprint: fingerprint,
                authenticationState: .authenticated
            ),
            handshakeError: handshakeError,
            heartbeatError: heartbeatError,
            heartbeatResponseOffset: heartbeatResponseOffset
        )
        clients.append(client)
        return client
    }

    func makeCount() -> Int { clients.count }
    func receivedPairingIDs() -> [Data] { pairingIDs }

    func closeCount() async -> Int {
        var count = 0
        for client in clients {
            count += await client.closeCount()
        }
        return count
    }
}

private actor SessionClientProbe: ProductSessionClient {
    private let result: HandshakeSmokeResult
    private let handshakeError: (any Error & Sendable)?
    private let heartbeatError: (any Error & Sendable)?
    private let heartbeatResponseOffset: Int64
    private var closes = 0

    init(
        handshake: HandshakeSmokeResult,
        handshakeError: (any Error & Sendable)?,
        heartbeatError: (any Error & Sendable)?,
        heartbeatResponseOffset: Int64
    ) {
        result = handshake
        self.handshakeError = handshakeError
        self.heartbeatError = heartbeatError
        self.heartbeatResponseOffset = heartbeatResponseOffset
    }

    func handshake() throws -> HandshakeSmokeResult {
        if let handshakeError { throw handshakeError }
        return result
    }

    func heartbeat(monotonicMillis: Int64) throws -> Droidmatch_V1_HeartbeatResponse {
        if let heartbeatError { throw heartbeatError }
        var response = Droidmatch_V1_HeartbeatResponse()
        response.monotonicMillis = monotonicMillis + heartbeatResponseOffset
        return response
    }

    func close() {
        closes += 1
    }

    func listDirectoryPage(
        query: DirectoryListingQuery,
        pageToken: String?
    ) throws -> DirectoryListingPage {
        DirectoryListingPage(entries: [], nextPageToken: nil)
    }

    func productDiagnosticsSnapshot() -> ProductDeviceDiagnosticsSnapshot {
        testDiagnosticsSnapshot()
    }

    func closeCount() -> Int { closes }
}

actor SessionPairingFactoryProbe {
    private let fingerprint: Data?
    private var count = 0

    init(fingerprint: Data? = nil) {
        self.fingerprint = fingerprint
    }

    func make(
        lease: DeviceConnectionLease,
        store: any PairingCredentialStoring
    ) -> any ProductPairingClient {
        count += 1
        return SessionPairingClientProbe(
            fingerprint: fingerprint ?? Data(repeating: 0, count: 32),
            store: store
        )
    }

    func makeCount() -> Int { count }
}

private actor SessionPairingClientProbe: ProductPairingClient {
    private let fingerprint: Data
    private let store: any PairingCredentialStoring
    private var closed = false

    init(fingerprint: Data, store: any PairingCredentialStoring) {
        self.fingerprint = fingerprint
        self.store = store
    }

    func pair(
        clientDisplayName: String,
        approve: @escaping @Sendable (PairingPresentation) async throws -> Bool
    ) async throws -> PairingCredentialRecord {
        let presentation = PairingPresentation(
            androidDisplayName: "Test Android",
            shortAuthenticationString: "123456",
            deviceIdentityFingerprint: fingerprint
        )
        guard try await approve(presentation) else {
            throw AsyncPairingClientError.userRejected
        }
        let record = try sessionCredentialRecord(fingerprint: fingerprint)
        try store.save(record)
        closed = true
        return record
    }

    func close() {
        closed = true
    }
}

func sessionCredentialRecord(
    fingerprint: Data,
    pairingID: Data = Data((0..<PairingAuthenticator.pairingIDLength).map { UInt8($0) }),
    pairingKey: Data = Data(repeating: 0xA5, count: PairingAuthenticator.keyLength)
) throws -> PairingCredentialRecord {
    try PairingCredentialRecord(
        pairingID: pairingID,
        deviceIdentityFingerprint: fingerprint,
        pairingKey: pairingKey,
        displayName: "Test Android",
        createdAt: Date(timeIntervalSince1970: 1),
        lastUsedAt: Date(timeIntervalSince1970: 2)
    )
}

private func testDiagnosticsSnapshot() -> ProductDeviceDiagnosticsSnapshot {
    ProductDeviceDiagnosticsSnapshot(
        manufacturer: "Example",
        model: "Phone",
        androidVersion: "14",
        sdkLevel: 34,
        totalStorageBytes: 1_000,
        freeStorageBytes: 400,
        batteryPercent: 70,
        permissions: [],
        serviceState: .connected,
        recentErrorCount: 0,
        counters: [:]
    )
}
