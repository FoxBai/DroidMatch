@testable import DroidMatchCore
import Foundation
import Testing

enum HeartbeatFailureCase: CaseIterable, Sendable {
    case transport
    case echoMismatch
}

private enum HeartbeatProbeError: Error, Sendable {
    case unavailable
}

@Test(arguments: HeartbeatFailureCase.allCases)
func productHeartbeatFailureTearsDownBeforePublishingTerminalEvent(
    failure: HeartbeatFailureCase
) async throws {
    let deviceID = UUID()
    let fingerprint = Data(repeating: 0x4a, count: PairingAuthenticator.digestLength)
    let record = try sessionCredentialRecord(fingerprint: fingerprint)
    let preparer = SessionConnectionPreparerProbe(deviceID: deviceID)
    let sessions = SessionClientFactoryProbe(
        fingerprint: fingerprint,
        heartbeatError: failure == .transport ? HeartbeatProbeError.unavailable : nil,
        heartbeatResponseOffset: failure == .echoMismatch ? 1 : 0
    )
    let coordinator = ProductDeviceSessionCoordinator(
        connectionPreparer: preparer,
        credentialStore: SessionCredentialStoreProbe(records: [record]),
        identityProbe: { _ in fingerprint },
        sessionFactory: { lease, credentials in
            await sessions.make(lease: lease, credentials: credentials)
        },
        pairingFactory: { _, _ in throw ProductDeviceSessionError.pairingNotRequired },
        keepaliveInterval: .zero
    )

    guard case .ready = try await coordinator.connect(to: deviceID) else {
        Issue.record("expected authenticated session")
        return
    }
    #expect(await waitForSessionClose(sessions))

    // Subscribe after teardown to prove the terminal event closes the ready-to-
    // observer race instead of relying on favorable task scheduling.
    let events = try await coordinator.sessionInvalidationEvents()
    #expect(await firstSessionEvent(events) == .connectionUnavailable)
    #expect(await sessions.closeCount() == 1)
    #expect(await preparer.releaseCount() == 1)
    await #expect(throws: ProductDeviceSessionError.noPreparedDevice) {
        _ = try await coordinator.directoryListingClient()
    }
    await #expect(throws: ProductDeviceSessionError.noPreparedDevice) {
        _ = try await coordinator.transferScheduler()
    }
}

@Test func productExplicitDisconnectFinishesSessionEventsWithoutFailure() async throws {
    let deviceID = UUID()
    let fingerprint = Data(repeating: 0x5a, count: PairingAuthenticator.digestLength)
    let record = try sessionCredentialRecord(fingerprint: fingerprint)
    let preparer = SessionConnectionPreparerProbe(deviceID: deviceID)
    let sessions = SessionClientFactoryProbe(fingerprint: fingerprint)
    let coordinator = ProductDeviceSessionCoordinator(
        connectionPreparer: preparer,
        credentialStore: SessionCredentialStoreProbe(records: [record]),
        identityProbe: { _ in fingerprint },
        sessionFactory: { lease, credentials in
            await sessions.make(lease: lease, credentials: credentials)
        },
        pairingFactory: { _, _ in throw ProductDeviceSessionError.pairingNotRequired },
        keepaliveInterval: .seconds(60)
    )

    guard case .ready = try await coordinator.connect(to: deviceID) else {
        Issue.record("expected authenticated session")
        return
    }
    let events = try await coordinator.sessionInvalidationEvents()
    await coordinator.disconnect()

    #expect(await firstSessionEvent(events) == nil)
    #expect(await sessions.closeCount() == 1)
    #expect(await preparer.releaseCount() == 1)
    await #expect(throws: ProductDeviceSessionError.noPreparedDevice) {
        _ = try await coordinator.sessionInvalidationEvents()
    }
}

@Test func replacementSessionCannotReceiveOldKeepaliveFailure() async throws {
    let deviceID = UUID()
    let fingerprint = LocalFrameTestServer.pairedDeviceIdentityFingerprint
    let firstRecord = try sessionCredentialRecord(fingerprint: fingerprint)
    let secondRecord = try sessionCredentialRecord(
        fingerprint: fingerprint,
        pairingID: Data(repeating: 0xb2, count: PairingAuthenticator.pairingIDLength),
        pairingKey: Data(repeating: 0xc2, count: PairingAuthenticator.keyLength)
    )
    let preparer = BlockingFirstReleasePreparer(deviceID: deviceID)
    let store = SessionCredentialStoreProbe(records: [firstRecord])
    let sessions = SequencedLivenessSessionFactory(fingerprint: fingerprint)
    let coordinator = ProductDeviceSessionCoordinator(
        connectionPreparer: preparer,
        credentialStore: store,
        identityProbe: { _ in fingerprint },
        sessionFactory: { _, credentials in
            await sessions.make(credentials: credentials)
        },
        pairingFactory: { _, _ in throw ProductDeviceSessionError.pairingNotRequired },
        keepaliveInterval: .milliseconds(5)
    )

    guard case .ready = try await coordinator.connect(to: deviceID) else {
        Issue.record("expected first authenticated session")
        return
    }
    let oldEvents = try await coordinator.sessionInvalidationEvents()
    guard await preparer.waitForFirstRelease() else {
        // The timeout is fatal to this test sequence: entering a replacement
        // connect before teardown owns the blocked release would deadlock the
        // test gate. Pre-opening the gate also makes this failure path safe if
        // releaseConnection arrives immediately after the timeout.
        await preparer.finishFirstRelease()
        await coordinator.disconnect()
        Issue.record("timed out waiting for keepalive teardown to start")
        return
    }
    store.replaceRecords([secondRecord])
    guard case .ready = try await coordinator.connect(to: deviceID) else {
        Issue.record("expected replacement authenticated session")
        return
    }
    let replacementEvents = try await coordinator.sessionInvalidationEvents()
    await preparer.finishFirstRelease()

    #expect(await firstSessionEvent(oldEvents) == nil)
    #expect(await firstSessionEvent(
        replacementEvents,
        timeout: .milliseconds(50)
    ) == nil)
    _ = try await coordinator.directoryListingClient()
    #expect(await sessions.receivedCredentials() == [
        .init(pairingID: firstRecord.pairingID, pairingKey: firstRecord.pairingKey),
        .init(pairingID: secondRecord.pairingID, pairingKey: secondRecord.pairingKey),
    ])
    let scheduler = try await coordinator.transferScheduler()
    #expect(await scheduler.snapshots().isEmpty)
    #expect(await sessions.closeCount() == 1)
    await coordinator.disconnect()
    #expect(await sessions.closeCount() == 2)
    #expect(await preparer.releaseCount() == 2)
}

@Test func productSessionEventChannelBroadcastsAndCachesTerminalEvent() async {
    let channel = ProductDeviceSessionEventChannel()
    let first = channel.stream()
    let second = channel.stream()

    channel.sendTerminal(.connectionUnavailable)

    #expect(await firstSessionEvent(first) == .connectionUnavailable)
    #expect(await firstSessionEvent(second) == .connectionUnavailable)
    #expect(await firstSessionEvent(channel.stream()) == .connectionUnavailable)
}

@Test func productSessionEventChannelCleanFinishCannotBecomeFailure() async {
    let channel = ProductDeviceSessionEventChannel()
    let events = channel.stream()

    channel.finish()
    channel.sendTerminal(.connectionUnavailable)

    #expect(await firstSessionEvent(events) == nil)
    #expect(await firstSessionEvent(channel.stream()) == nil)
}

private func waitForSessionClose(_ sessions: SessionClientFactoryProbe) async -> Bool {
    for _ in 0..<200 {
        if await sessions.closeCount() == 1 { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return false
}

private func firstSessionEvent(
    _ stream: AsyncStream<ProductDeviceSessionEvent>,
    timeout: Duration = .seconds(1)
) async -> ProductDeviceSessionEvent? {
    await withTaskGroup(of: ProductDeviceSessionEvent?.self) { group in
        group.addTask {
            var iterator = stream.makeAsyncIterator()
            return await iterator.next()
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return nil
        }
        let result = await group.next() ?? nil
        group.cancelAll()
        return result
    }
}

private actor BlockingFirstReleasePreparer: DeviceConnectionPreparing {
    private let deviceID: UUID
    private let port: Int
    private let firstReleaseStarted = AsyncRpcOneShot<Void>()
    private var releases = 0
    private var firstReleaseFinished = false
    private var firstReleaseContinuation: CheckedContinuation<Void, Never>?

    init(deviceID: UUID, port: Int = 45_601) {
        self.deviceID = deviceID
        self.port = port
    }

    func prepareConnection(to deviceID: UUID) throws -> DeviceConnectionLease {
        guard deviceID == self.deviceID else {
            throw DeviceConnectionPreparationError.deviceUnavailable
        }
        return DeviceConnectionLease(deviceID: deviceID, host: "127.0.0.1", port: port)
    }

    func releaseConnection(_ lease: DeviceConnectionLease) async {
        _ = lease
        releases += 1
        guard releases == 1 else { return }
        firstReleaseStarted.resolve(.success(()))
        guard !firstReleaseFinished else { return }
        await withCheckedContinuation { continuation in
            if firstReleaseFinished {
                continuation.resume()
            } else {
                firstReleaseContinuation = continuation
            }
        }
    }

    func waitForFirstRelease(timeout: Duration = .seconds(1)) async -> Bool {
        let started = firstReleaseStarted
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do {
                    try await started.wait(onCancel: {})
                    return true
                } catch {
                    return false
                }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }

    func finishFirstRelease() {
        firstReleaseFinished = true
        firstReleaseContinuation?.resume()
        firstReleaseContinuation = nil
    }

    func releaseCount() -> Int { releases }
}

private actor SequencedLivenessSessionFactory {
    private let fingerprint: Data
    private var clients: [LivenessSessionClient] = []
    private var credentialsSeen: [LivenessCredentialIdentity] = []

    init(fingerprint: Data) {
        self.fingerprint = fingerprint
    }

    func make(credentials: PairingCredentials) -> any ProductSessionClient {
        credentialsSeen.append(.init(
            pairingID: credentials.pairingID,
            pairingKey: credentials.pairingKey
        ))
        let client = LivenessSessionClient(
            fingerprint: fingerprint,
            failsHeartbeat: clients.isEmpty
        )
        clients.append(client)
        return client
    }

    func receivedCredentials() -> [LivenessCredentialIdentity] { credentialsSeen }

    func closeCount() async -> Int {
        var result = 0
        for client in clients {
            result += await client.closeCount()
        }
        return result
    }
}

private struct LivenessCredentialIdentity: Sendable, Equatable {
    let pairingID: Data
    let pairingKey: Data
}

private actor LivenessSessionClient: ProductSessionClient {
    private let fingerprint: Data
    private let failsHeartbeat: Bool
    private var closes = 0

    init(fingerprint: Data, failsHeartbeat: Bool) {
        self.fingerprint = fingerprint
        self.failsHeartbeat = failsHeartbeat
    }

    func handshake() -> HandshakeSmokeResult {
        HandshakeSmokeResult(
            requestID: 1,
            serverName: "Test Android",
            serverVersion: "test",
            protocolMajor: 1,
            protocolMinor: 0,
            transport: .adb,
            grantedCapabilities: [.fileList, .fileRead, .resumableTransfer, .diagnostics],
            sessionNonce: Data(repeating: 1, count: 32),
            serverNonce: Data(repeating: 2, count: 32),
            deviceIdentityFingerprint: fingerprint,
            authenticationState: .authenticated
        )
    }

    func heartbeat(monotonicMillis: Int64) throws -> Droidmatch_V1_HeartbeatResponse {
        if failsHeartbeat { throw HeartbeatProbeError.unavailable }
        var response = Droidmatch_V1_HeartbeatResponse()
        response.monotonicMillis = monotonicMillis
        return response
    }

    func close() { closes += 1 }

    func listDirectoryPage(
        query: DirectoryListingQuery,
        pageToken: String?
    ) -> DirectoryListingPage {
        _ = query
        _ = pageToken
        return DirectoryListingPage(entries: [], nextPageToken: nil)
    }

    func productDiagnosticsSnapshot() -> ProductDeviceDiagnosticsSnapshot {
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

    func closeCount() -> Int { closes }
}
