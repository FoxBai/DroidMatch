import Foundation
@preconcurrency import Network
import Testing
@testable import DroidMatchCore

@Test(arguments: ["dm://media-images/source.jpg", "dm://media-audio/source.mp3"])
func mediaStoreProductCancellationUsesActiveTransferBeforeSettling(destination: String) async throws {
    let fixture = try MediaStoreCancellationFixture(mode: .heldSuccess, destination: destination)
    defer { fixture.close() }
    let scheduler = fixture.makeScheduler()
    let job = await scheduler.submit(.upload(fixture.request))

    #expect(await fixture.server.waitForChunkCount(4))
    let cancellation = Task { await scheduler.cancel(job) }
    #expect(await fixture.server.waitForCancelCount(1))
    #expect(fixture.server.cancelTransferIDs == [fixture.transferID])
    #expect(fixture.server.connectionIsOpen)
    let cleaning = try await scheduler.snapshot(for: job)
    #expect(cleaning.state == .cleaning)
    #expect(!cleaning.state.isTerminal)

    fixture.server.releaseHeldCancelSuccess()
    #expect(await cancellation.value)
    assertCancelled(try await scheduler.waitForCompletion(job))
    #expect(try await scheduler.snapshot(for: job).state == .cancelled)
    #expect(fixture.server.chunkCount == 4)
}

@Test func mediaStoreProductCancellationFailureRetainsRouteForRetry() async throws {
    let fixture = try MediaStoreCancellationFixture(mode: .failureThenSuccess)
    defer { fixture.close() }
    let scheduler = fixture.makeScheduler()
    let job = await scheduler.submit(.upload(fixture.request))

    #expect(await fixture.server.waitForChunkCount(4))
    #expect(!(await scheduler.cancel(job)))
    let failedCancel = try await scheduler.snapshot(for: job)
    #expect(failedCancel.state == .cleaning)
    #expect(!failedCancel.state.isTerminal)
    #expect(failedCancel.canCancel)
    #expect(failedCancel.failureCode == .remoteInternal)
    #expect(fixture.server.connectionIsOpen)
    try await Task.sleep(for: .milliseconds(50))
    #expect(fixture.server.chunkCount == 4)

    #expect(await scheduler.cancel(job))
    assertCancelled(try await scheduler.waitForCompletion(job))
    #expect(fixture.server.cancelTransferIDs == [
        fixture.transferID,
        fixture.transferID,
    ])
    #expect(fixture.server.chunkCount == 4)
}

@Test func mediaStoreProductCancellationLosesToFinalAcknowledgement() async throws {
    let fixture = try MediaStoreCancellationFixture(
        mode: .finalAcknowledgementWins,
        sourceData: Data("ok".utf8)
    )
    defer { fixture.close() }
    let scheduler = fixture.makeScheduler()
    let job = await scheduler.submit(.upload(fixture.request))

    #expect(await fixture.server.waitForChunkCount(1))
    let cancellation = Task { await scheduler.cancel(job) }
    #expect(await fixture.server.waitForCancelCount(1))
    fixture.server.releaseFinalAcknowledgement()
    assertSuccess(try await scheduler.waitForCompletion(job))
    #expect(!(await cancellation.value))
    #expect(try await scheduler.snapshot(for: job).state == .completed)

    fixture.server.releaseHeldCancelSuccess()
    #expect(await fixture.server.waitForCancelResponseSent())
    #expect(fixture.server.cancelTransferIDs == [fixture.transferID])
}

@Test func mediaStoreFinalAcknowledgementPreservesPostAckSourceFailure() async throws {
    let fixture = try MediaStoreCancellationFixture(
        mode: .finalAcknowledgementWins,
        sourceData: Data("ok".utf8)
    )
    defer { fixture.close() }
    let scheduler = fixture.makeScheduler()
    let job = await scheduler.submit(.upload(fixture.request))

    #expect(await fixture.server.waitForChunkCount(1))
    let cancellation = Task { await scheduler.cancel(job) }
    #expect(await fixture.server.waitForCancelCount(1))
    try Data("source changed after send".utf8).write(to: fixture.sourceURL)
    fixture.server.releaseFinalAcknowledgement()

    guard case let .failure(description) = try await scheduler.waitForCompletion(job) else {
        Issue.record("post-ACK source validation must remain authoritative")
        return
    }
    #expect(description == AsyncTransferFailureLabel.uploadSource)
    #expect(!(await cancellation.value))
    let failed = try await scheduler.snapshot(for: job)
    #expect(failed.state == .failed)
    #expect(failed.failureCode == .uploadSource)

    fixture.server.releaseHeldCancelSuccess()
    #expect(await fixture.server.waitForCancelResponseSent())
}

@Test func mediaStoreFinishPreservesTruthAfterCancellationAlreadyLost() {
    let dispositions: [(
        AsyncActiveUploadCancellationController.TransferEndDisposition,
        AsyncTransferJobState
    )] = [
        (.finalAcknowledged, .cleaning),
        (.finalAcknowledged, .interrupted),
        (.ordinary, .cleaning),
    ]

    for (disposition, state) in dispositions {
        var record = mediaStoreFinishPolicyRecord(state: state)
        let resolution = AsyncActiveUploadCancellationFinishPolicy.reconcile(
            .failure(AsyncTransferFailureLabel.uploadSource),
            activeUploadEndDisposition: disposition,
            with: &record,
            at: 1
        )
        guard case let .terminal(.failure(description)) = resolution else {
            Issue.record("a late cancel must preserve the executor failure")
            continue
        }
        #expect(description == AsyncTransferFailureLabel.uploadSource)
        #expect(record.state == .failed)
        #expect(record.activeUploadCancellationController == nil)
    }
}

@Test func mediaStoreProductCancellationSurvivesPreOpenSourceFailure() async throws {
    let gate = NonCooperativeSchedulerGate()
    let fixture = try MediaStoreCancellationFixture(mode: .heldSuccess)
    defer { fixture.close() }
    let scheduler = fixture.makeScheduler(startGate: gate)
    let job = await scheduler.submit(.upload(fixture.request))
    #expect(await gate.waitUntilStarted())

    let cancellation = Task { await scheduler.cancel(job) }
    _ = try #require(await waitForSchedulerSnapshot(
        scheduler: scheduler,
        id: job,
        matching: { $0.state == .cleaning }
    ))
    try FileManager.default.removeItem(at: fixture.sourceURL)
    gate.release()

    #expect(await cancellation.value)
    assertCancelled(try await scheduler.waitForCompletion(job))
    #expect(fixture.factoryCalls == 0)
    #expect(fixture.server.connectionCount == 0)
    #expect(fixture.server.cancelTransferIDs.isEmpty)
}

@Test func mediaStoreProductCancellationSurvivesExecutorPreflightFailure() async throws {
    let gate = NonCooperativeSchedulerGate()
    let fixture = try MediaStoreCancellationFixture(mode: .heldSuccess)
    defer { fixture.close() }
    let scheduler = AsyncTransferScheduler(
        maxConcurrentJobs: 1,
        downloadExecutor: { request, _, _ in
            downloadResult(request.sourcePath, attemptCount: 1)
        },
        uploadExecutor: { _, _, _ in
            await gate.wait()
            throw RpcControlClientError.invalidTransferState("access unavailable")
        }
    )
    let job = await scheduler.submit(.upload(fixture.request))
    #expect(await gate.waitUntilStarted())

    let cancellation = Task { await scheduler.cancel(job) }
    _ = try #require(await waitForSchedulerSnapshot(
        scheduler: scheduler,
        id: job,
        matching: { $0.state == .cleaning }
    ))
    gate.release()

    #expect(await cancellation.value)
    assertCancelled(try await scheduler.waitForCompletion(job))
    #expect(fixture.server.connectionCount == 0)
}

@Test func lateMediaStoreCancellationRestoresOriginalFailureTruth() async throws {
    let finishGate = NonCooperativeSchedulerGate()
    let fixture = try MediaStoreCancellationFixture(mode: .heldSuccess, persistent: true)
    defer { fixture.close() }
    let scheduler = AsyncTransferScheduler(
        maxConcurrentJobs: 1,
        downloadExecutor: { request, _, _ in
            downloadResult(request.sourcePath, attemptCount: 1)
        },
        uploadExecutor: { request, _, _ in
            guard let controller = request.activeCancellationController else {
                throw RpcControlClientError.invalidTransferState("missing controller")
            }
            guard await controller.transferEnded() == .ordinary else {
                throw RpcControlClientError.invalidTransferState("unexpected cancellation")
            }
            await finishGate.wait()
            throw SchedulerTestError.retryable
        },
        persistenceStore: fixture.persistenceStore
    )
    let job = await scheduler.submit(.upload(fixture.request))
    #expect(await finishGate.waitUntilStarted())

    #expect(!(await scheduler.cancel(job)))
    #expect(try await scheduler.snapshot(for: job).state == .running)
    #expect(try fixture.persistenceStore?.load().jobs.first?.state == .active)
    finishGate.release()

    guard case let .failure(description) = try await scheduler.waitForCompletion(job) else {
        Issue.record("late cancellation must preserve the executor failure")
        return
    }
    #expect(description == AsyncTransferFailureLabel.transfer)
    let failed = try await scheduler.snapshot(for: job)
    #expect(failed.state == .failed)
    #expect(failed.failureCode == .transfer)
}

@Test func mediaStoreProductCancellationSessionLossStaysInterruptedWithoutReplay() async throws {
    let fixture = try MediaStoreCancellationFixture(
        mode: .failureThenDisconnect,
        persistent: true
    )
    defer { fixture.close() }
    let store = try #require(fixture.persistenceStore)
    let scheduler = fixture.makeScheduler()
    let job = await scheduler.submit(.upload(fixture.request))

    #expect(await fixture.server.waitForChunkCount(4))
    #expect(!(await scheduler.cancel(job)))
    #expect(try await scheduler.snapshot(for: job).canCancel)
    fixture.server.disconnectAfterFailure()

    let outcome = try await scheduler.waitForCompletion(job)
    assertCleanupUnverified(outcome)
    let interrupted = try await scheduler.snapshot(for: job)
    #expect(interrupted.state == .interrupted)
    #expect(interrupted.failureDescription == AsyncActiveUploadCancellationController
        .cleanupUnverifiedFailureDescription)
    #expect(fixture.factoryCalls == 1)
    #expect(try store.load().jobs.first?.state == .interrupted)

    let replayCalls = MediaStoreCancellationCounter()
    let restored = try await AsyncTransferScheduler.restoring(
        maxConcurrentJobs: 1,
        persistenceStore: store,
        downloadExecutor: { request, _, _ in
            downloadResult(request.sourcePath, attemptCount: 1)
        },
        uploadExecutor: { request, _, _ in
            replayCalls.increment()
            return uploadResult(request.sourceURL.path, attemptCount: 1)
        }
    )
    try await Task.sleep(for: .milliseconds(50))
    let restoredSnapshot = try await restored.snapshot(for: job)
    #expect(restoredSnapshot.state == .interrupted)
    #expect(restoredSnapshot.failureDescription == AsyncActiveUploadCancellationController
        .cleanupUnverifiedFailureDescription)
    #expect(replayCalls.value == 0)
}

enum MediaStoreSessionEnd: CaseIterable, Sendable {
    case shutdownRunning
    case shutdownCleaning
    case suspensionRunning
    case suspensionCleaning

    var beginsCancellation: Bool {
        self == .shutdownCleaning || self == .suspensionCleaning
    }
}

@Test(arguments: MediaStoreSessionEnd.allCases)
func mediaStoreSessionEndNeverClaimsUnconfirmedCancellation(
    _ sessionEnd: MediaStoreSessionEnd
) async throws {
    let fixture = try MediaStoreCancellationFixture(mode: .heldSuccess)
    defer { fixture.close() }
    let scheduler = fixture.makeScheduler()
    let job = await scheduler.submit(.upload(fixture.request))
    #expect(await fixture.server.waitForChunkCount(4))
    let cancellation = sessionEnd.beginsCancellation
        ? Task { await scheduler.cancel(job) }
        : nil
    if cancellation != nil {
        #expect(await fixture.server.waitForCancelCount(1))
    }

    switch sessionEnd {
    case .shutdownRunning, .shutdownCleaning:
        await scheduler.shutdown()
    case .suspensionRunning, .suspensionCleaning:
        await scheduler.suspendForSessionEnd()
    }

    if let cancellation { #expect(!(await cancellation.value)) }
    assertCleanupUnverified(try await scheduler.waitForCompletion(job))
    let interrupted = try await scheduler.snapshot(for: job)
    #expect(interrupted.state == .interrupted)
    #expect(interrupted.failureDescription == AsyncActiveUploadCancellationController
        .cleanupUnverifiedFailureDescription)
    #expect(fixture.server.cancelTransferIDs.count == (sessionEnd.beginsCancellation ? 1 : 0))
}

private func assertCleanupUnverified(
    _ outcome: AsyncTransferJobOutcome,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    guard case let .failure(description) = outcome else {
        Issue.record("expected cleanup-unverified failure", sourceLocation: sourceLocation)
        return
    }
    #expect(
        description == AsyncActiveUploadCancellationController
            .cleanupUnverifiedFailureDescription,
        sourceLocation: sourceLocation
    )
}

private func mediaStoreFinishPolicyRecord(
    state: AsyncTransferJobState
) -> AsyncTransferSchedulerJobRecord {
    let request = AsyncUploadCoordinatorRequest(
        sourceURL: URL(fileURLWithPath: "/tmp/mediastore-finish-policy.jpg"),
        destinationPath: "dm://media-images/mediastore-finish-policy.jpg",
        freshTransferID: "mediastore-finish-policy"
    )
    var record = AsyncTransferSchedulerJobRecord(
        id: UUID(),
        sequence: 0,
        request: .upload(request),
        kind: .upload,
        source: request.sourceURL.path,
        destination: request.destinationPath,
        supportsCheckpointPause: false,
        state: state
    )
    AsyncActiveUploadCancellationController.installIfNeeded(in: &record)
    return record
}

private final class MediaStoreCancellationFixture: @unchecked Sendable {
    let directory: URL
    let sourceURL: URL
    let destination: String
    let transferID = UUID().uuidString
    let server: MediaStoreCancellationWireServer
    let persistenceStore: TransferQueuePersistenceStore?
    private let coordinator: AsyncUploadCoordinator
    private let counter = MediaStoreCancellationCounter()

    init(
        mode: MediaStoreCancellationWireServer.Mode,
        sourceData: Data = Data("abcdefghij".utf8),
        persistent: Bool = false,
        destination: String = "dm://media-images/source.jpg"
    ) throws {
        self.destination = destination
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "droidmatch-mediastore-cancel-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        sourceURL = directory.appendingPathComponent(String(destination.split(separator: "/").last!))
        try sourceData.write(to: sourceURL)
        server = try MediaStoreCancellationWireServer(mode: mode, destination: destination)
        persistenceStore = persistent ? try TransferQueuePersistenceStore(
            fileURL: directory.appendingPathComponent("queue.json")
        ) : nil
        let port = server.port
        let counter = self.counter
        coordinator = AsyncUploadCoordinator(clientFactory: { _ in
            counter.increment()
            let session = try await AsyncFramedTcpSession.connect(
                port: port,
                timeoutSeconds: 2
            )
            return AsyncRpcControlClient(
                session: session,
                requestedCapabilities: [.fileWrite, .resumableTransfer],
                requestTimeoutSeconds: 2
            )
        })
    }

    var factoryCalls: Int { counter.value }

    var request: AsyncUploadCoordinatorRequest {
        AsyncUploadCoordinatorRequest(
            sourceURL: sourceURL,
            destinationPath: destination,
            freshTransferID: transferID,
            preferredChunkSizeBytes: 2
        )
    }

    func makeScheduler(
        startGate: NonCooperativeSchedulerGate? = nil
    ) -> AsyncTransferScheduler {
        let coordinator = coordinator
        return AsyncTransferScheduler(
            maxConcurrentJobs: 1,
            downloadExecutor: { request, _, _ in
                downloadResult(request.sourcePath, attemptCount: 1)
            },
            uploadExecutor: { request, retry, progress in
                if let startGate { await startGate.wait() }
                return try await coordinator.upload(
                    request,
                    onRetry: retry,
                    onProgress: progress
                )
            },
            persistenceStore: persistenceStore
        )
    }

    func close() {
        server.cancel()
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class MediaStoreCancellationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

private final class MediaStoreCancellationWireServer: @unchecked Sendable {
    enum Mode {
        case heldSuccess
        case failureThenSuccess
        case finalAcknowledgementWins
        case failureThenDisconnect
    }

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var mode: Mode
        private var connection: NWConnection?
        private var open = false
        private var connections = 0
        private var chunks = 0
        private var transferIDs: [String] = []
        private var uploadRequestID: UInt64?
        private var transferID: String?
        private var finalOffset: Int64?
        private var heldCancelRequestID: UInt64?
        private var cancelResponseSent = false

        let destination: String
        init(mode: Mode, destination: String) { self.mode = mode; self.destination = destination }

        var connectionIsOpen: Bool { lock.withLock { open } }
        var connectionCount: Int { lock.withLock { connections } }
        var chunkCount: Int { lock.withLock { chunks } }
        var cancelTransferIDs: [String] { lock.withLock { transferIDs } }
        var didSendCancelResponse: Bool { lock.withLock { cancelResponseSent } }

        func accept(_ connection: NWConnection) {
            lock.withLock {
                self.connection = connection
                connections += 1
                open = true
            }
            connection.stateUpdateHandler = { [weak self] state in
                if case .failed = state { self?.markClosed() }
                if case .cancelled = state { self?.markClosed() }
            }
        }

        func markClosed() { lock.withLock { open = false } }

        func recordOpen(requestID: UInt64, transferID: String) {
            lock.withLock {
                uploadRequestID = requestID
                self.transferID = transferID
            }
        }

        func recordChunk(finalOffset: Int64?) {
            lock.withLock {
                chunks += 1
                if let finalOffset { self.finalOffset = finalOffset }
            }
        }

        func recordCancel(requestID: UInt64, transferID: String) -> Int {
            lock.withLock {
                transferIDs.append(transferID)
                heldCancelRequestID = requestID
                return transferIDs.count
            }
        }

        func wireValues() -> (
            connection: NWConnection,
            uploadRequestID: UInt64,
            transferID: String,
            finalOffset: Int64,
            cancelRequestID: UInt64
        )? {
            lock.withLock {
                guard let connection, let uploadRequestID, let transferID,
                      let finalOffset, let cancelRequestID = heldCancelRequestID else {
                    return nil
                }
                return (
                    connection,
                    uploadRequestID,
                    transferID,
                    finalOffset,
                    cancelRequestID
                )
            }
        }

        func cancelValues() -> (NWConnection, UInt64, String)? {
            lock.withLock {
                guard let connection, let requestID = heldCancelRequestID,
                      let transferID else { return nil }
                return (connection, requestID, transferID)
            }
        }

        func markCancelResponseSent() {
            lock.withLock { cancelResponseSent = true }
        }

        func disconnect() {
            let connection = lock.withLock { self.connection }
            connection?.cancel()
            markClosed()
        }
    }

    private let listener: LocalFrameTestServer
    private let state: State
    let port: Int

    init(mode: Mode, destination: String) throws {
        let state = State(mode: mode, destination: destination)
        self.state = state
        listener = try LocalFrameTestServer { connection in
            state.accept(connection)
            Self.readHandshake(on: connection, state: state)
        }
        port = listener.port
    }

    var connectionIsOpen: Bool { state.connectionIsOpen }
    var connectionCount: Int { state.connectionCount }
    var chunkCount: Int { state.chunkCount }
    var cancelTransferIDs: [String] { state.cancelTransferIDs }

    func cancel() { listener.cancel(); state.disconnect() }
    func disconnectAfterFailure() { state.disconnect() }

    func waitForChunkCount(_ count: Int) async -> Bool {
        await waitUntil { self.state.chunkCount == count }
    }

    func waitForCancelCount(_ count: Int) async -> Bool {
        await waitUntil { self.state.cancelTransferIDs.count == count }
    }

    func waitForCancelResponseSent() async -> Bool {
        await waitUntil { self.state.didSendCancelResponse }
    }

    func releaseHeldCancelSuccess() {
        guard let (connection, requestID, transferID) = state.cancelValues() else { return }
        Self.sendCancelResponse(
            on: connection,
            requestID: requestID,
            transferID: transferID,
            succeeds: true,
            state: state,
            completion: {}
        )
    }

    func releaseFinalAcknowledgement() {
        guard let values = state.wireValues() else { return }
        do {
            var acknowledgement = Droidmatch_V1_TransferChunkAck()
            acknowledgement.transferID = values.transferID
            acknowledgement.nextOffsetBytes = values.finalOffset
            acknowledgement.finalAck = true
            var envelope = Droidmatch_V1_RpcEnvelope()
            envelope.frameVersion = 1
            envelope.kind = .stream
            envelope.requestID = values.uploadRequestID
            envelope.streamID = values.uploadRequestID
            envelope.payloadType = .transferChunkAck
            envelope.payload = try acknowledgement.serializedData()
            LocalFrameTestServer.send(
                [try envelope.serializedData()],
                on: values.connection,
                completion: {}
            )
        } catch {
            state.disconnect()
        }
    }

    private static func readHandshake(on connection: NWConnection, state: State) {
        LocalFrameTestServer.receiveFrameBody(on: connection) { body in
            do {
                let response = try LocalFrameTestServer.handshakeResponse(to: body)
                LocalFrameTestServer.send([response], on: connection) {
                    readOpen(on: connection, state: state)
                }
            } catch {
                state.disconnect()
            }
        }
    }

    private static func readOpen(on connection: NWConnection, state: State) {
        LocalFrameTestServer.receiveFrameBody(on: connection) { body in
            do {
                let envelope = try Droidmatch_V1_RpcEnvelope(serializedBytes: body)
                guard envelope.payloadType == .openTransferRequest else {
                    throw LocalEchoServerError.unexpectedPayloadType
                }
                let request = try Droidmatch_V1_OpenTransferRequest(
                    serializedBytes: envelope.payload
                )
                guard request.direction == .upload,
                      request.destinationPath == state.destination else {
                    throw LocalEchoServerError.unexpectedPayloadType
                }
                state.recordOpen(requestID: envelope.requestID, transferID: request.transferID)
                var response = Droidmatch_V1_OpenTransferResponse()
                response.transferID = request.transferID
                response.acceptedOffsetBytes = 0
                response.chunkSizeBytes = 2
                response.totalSizeBytes = request.expectedSizeBytes
                response.streamID = envelope.requestID
                var responseEnvelope = Droidmatch_V1_RpcEnvelope()
                responseEnvelope.frameVersion = 1
                responseEnvelope.kind = .response
                responseEnvelope.requestID = envelope.requestID
                responseEnvelope.payloadType = .openTransferResponse
                responseEnvelope.payload = try response.serializedData()
                LocalFrameTestServer.send(
                    [try responseEnvelope.serializedData()],
                    on: connection
                ) {
                    readNext(on: connection, state: state)
                }
            } catch {
                state.disconnect()
            }
        }
    }

    private static func readNext(on connection: NWConnection, state: State) {
        LocalFrameTestServer.receiveFrameBody(on: connection) { body in
            do {
                let envelope = try Droidmatch_V1_RpcEnvelope(serializedBytes: body)
                switch envelope.payloadType {
                case .transferChunk:
                    let chunk = try Droidmatch_V1_TransferChunk(
                        serializedBytes: envelope.payload
                    )
                    guard chunk.crc32 == Crc32.checksum(chunk.data) else {
                        throw LocalEchoServerError.unexpectedPayloadType
                    }
                    state.recordChunk(finalOffset: chunk.finalChunk
                        ? chunk.offsetBytes + Int64(chunk.data.count) : nil)
                    readNext(on: connection, state: state)
                case .cancelTransferRequest:
                    let cancel = try Droidmatch_V1_CancelTransferRequest(
                        serializedBytes: envelope.payload
                    )
                    let attempt = state.recordCancel(
                        requestID: envelope.requestID,
                        transferID: cancel.transferID
                    )
                    switch state.mode {
                    case .heldSuccess, .finalAcknowledgementWins:
                        break
                    case .failureThenSuccess where attempt == 1,
                         .failureThenDisconnect where attempt == 1:
                        sendCancelResponse(
                            on: connection,
                            requestID: envelope.requestID,
                            transferID: cancel.transferID,
                            succeeds: false,
                            state: state
                        ) {
                            readNext(on: connection, state: state)
                        }
                    case .failureThenSuccess:
                        sendCancelResponse(
                            on: connection,
                            requestID: envelope.requestID,
                            transferID: cancel.transferID,
                            succeeds: true,
                            state: state,
                            completion: {}
                        )
                    case .failureThenDisconnect:
                        throw LocalEchoServerError.unexpectedPayloadType
                    }
                default:
                    throw LocalEchoServerError.unexpectedPayloadType
                }
            } catch {
                state.disconnect()
            }
        }
    }

    private static func sendCancelResponse(
        on connection: NWConnection,
        requestID: UInt64,
        transferID: String,
        succeeds: Bool,
        state: State,
        completion: @escaping @Sendable () -> Void
    ) {
        do {
            var response = Droidmatch_V1_CancelTransferResponse()
            response.transferID = transferID
            response.ok = succeeds
            if !succeeds {
                var error = Droidmatch_V1_DroidMatchError()
                error.code = .internal
                error.message = "provider cleanup was not confirmed"
                response.error = error
            }
            var envelope = Droidmatch_V1_RpcEnvelope()
            envelope.frameVersion = 1
            envelope.kind = .response
            envelope.requestID = requestID
            envelope.payloadType = .cancelTransferResponse
            envelope.payload = try response.serializedData()
            LocalFrameTestServer.send(
                [try envelope.serializedData()],
                on: connection
            ) {
                state.markCancelResponseSent()
                completion()
            }
        } catch {
            state.disconnect()
        }
    }
}

private func waitUntil(_ predicate: @escaping @Sendable () -> Bool) async -> Bool {
    for _ in 0..<400 {
        if predicate() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return false
}
