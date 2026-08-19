import Foundation

/// One live, fresh-only MediaStore upload cancellation transaction.
///
/// The controller never owns queue state or persistence. It keeps the original
/// upload handle alive across a rejected remote cancel so a later user retry
/// targets the same session, transfer ID, provider writer, and path lease.
actor AsyncActiveUploadCancellationController {
    static let cleanupUnverifiedFailureDescription =
        "fresh upload cleanup could not be verified"

    enum AttemptResult: Sendable, Equatable {
        case confirmed
        case failed(String)
        case completed
        case cleanupUnverified
    }

    enum TransferEndDisposition: Sendable, Equatable {
        case ordinary
        case finalAcknowledged
        case cancelled
        case cleanupUnverified
    }

    private enum TerminalState {
        case cancelled
        case completed
        case cleanupUnverified
        case ended
    }

    private var cancellationOperation: (@Sendable () async throws -> Void)?
    private var cancellationRequested = false
    private var confirmationAwaitsScheduler = false
    private var remoteOpenMayExist = false
    private var terminalState: TerminalState?
    private var wireAttemptTask: Task<Void, Never>?
    private var wireAttemptCompletionWaiters: [UUID: AsyncRpcOneShot<Void>] = [:]
    private var attemptContinuation: CheckedContinuation<AttemptResult, Never>?
    private var sendGateWaiters: [UUID: AsyncRpcOneShot<Void>] = [:]

    static func installIfNeeded(in record: inout AsyncTransferSchedulerJobRecord) {
        guard case let .upload(request) = record.request,
              request.isFreshOnlyMediaStoreDestination else { return }
        let controller = Self()
        record.activeUploadCancellationController = controller
        record.request = .upload(request.controllingActiveCancellation(with: controller))
    }

    static func uninstall(from record: inout AsyncTransferSchedulerJobRecord) {
        guard case let .upload(request) = record.request else { return }
        record.request = .upload(request.controllingActiveCancellation(with: nil))
        record.activeUploadCancellationController = nil
    }

    /// Returns only after this particular user attempt has a remote/local
    /// confirmation, a stable rejection, or an unverified session end.
    func requestCancellation() async -> AttemptResult {
        if let terminalState {
            return result(for: terminalState)
        }
        guard attemptContinuation == nil, !confirmationAwaitsScheduler else {
            return .failed(AsyncTransferFailureLabel.transfer)
        }
        cancellationRequested = true
        return await withCheckedContinuation { continuation in
            attemptContinuation = continuation
            startWireAttemptIfPossible()
        }
    }

    /// Called immediately before an open request can create a remote row.
    /// A cancellation already admitted at this boundary is locally conclusive:
    /// no transfer route or provider object exists yet.
    func beginRemoteOpen() async throws {
        if let terminalState { return try terminalResult(terminalState) }
        if cancellationRequested {
            beginLocalConfirmationIfNeeded()
            try await waitForSendAdmission()
            return
        }
        remoteOpenMayExist = true
    }

    /// Registration happens before the first source window is admitted. If an
    /// open response raced cancellation, the same handle performs wire cancel.
    func register(_ transfer: AsyncUploadTransfer) {
        registerCancellationOperation {
            _ = try await transfer.cancel(reason: "product-mediastore-upload-cancel")
        }
    }

    /// The closure retains the exact active handle. Keeping this narrow seam
    /// also lets deterministic tests force ACK-wakeup ahead of cancel return.
    func registerCancellationOperation(
        _ operation: @escaping @Sendable () async throws -> Void
    ) {
        guard terminalState == nil else { return }
        cancellationOperation = operation
        startWireAttemptIfPossible()
    }

    /// Blocks initial sending and every non-final refill once cancellation has
    /// been requested. A failed cancel deliberately leaves this gate closed.
    func waitForSendAdmission() async throws {
        if let terminalState {
            return try terminalResult(terminalState)
        }
        guard cancellationRequested || confirmationAwaitsScheduler else { return }
        let id = UUID()
        let waiter = AsyncRpcOneShot<Void>()
        sendGateWaiters[id] = waiter
        do {
            try await waiter.wait(cancellationPolicy: .firstResolutionWins, onCancel: {})
            sendGateWaiters.removeValue(forKey: id)
        } catch {
            sendGateWaiters.removeValue(forKey: id)
            throw error
        }
    }

    /// A final ACK is the remote publication confirmation. Once observed first,
    /// a later cancel response cannot overwrite completion.
    func markFinalAcknowledged() {
        guard terminalState == nil, !confirmationAwaitsScheduler else { return }
        terminalState = .completed
        cancellationOperation = nil
        resolveAttempt(.completed)
        resolveSendGate(.success(()))
    }

    /// The scheduler persists its non-terminal intent before releasing the
    /// coordinator from a successful cancellation response.
    func acknowledgeSchedulerConfirmation() {
        guard terminalState == nil, confirmationAwaitsScheduler else { return }
        terminalState = .cancelled
        confirmationAwaitsScheduler = false
        cancellationOperation = nil
        resolveSendGate(.failure(CancellationError()))
    }

    /// A successful wire cancel that lost the subsequent local persistence
    /// boundary cannot be presented as terminal cancellation. Keep the sender
    /// stopped and report cleanup-unverified instead.
    func rejectSchedulerConfirmation() {
        guard terminalState == nil, confirmationAwaitsScheduler else { return }
        terminalState = .cleanupUnverified
        confirmationAwaitsScheduler = false
        cancellationOperation = nil
        resolveSendGate(.failure(AsyncActiveUploadCancellationError.cleanupUnverified))
    }

    /// Makes session teardown conservative before the executor is cancelled.
    /// The scheduler publishes its interrupted record first, so waking a sender
    /// here cannot race back into terminal cancellation.
    func sessionEnded() -> Bool {
        if let terminalState {
            if case .cleanupUnverified = terminalState { return true }
            return false
        }
        terminalState = .cleanupUnverified
        confirmationAwaitsScheduler = false
        cancellationOperation = nil
        wireAttemptTask?.cancel()
        resolveAttempt(.cleanupUnverified)
        resolveWireAttemptWaiters()
        resolveSendGate(.failure(AsyncActiveUploadCancellationError.cleanupUnverified))
        return true
    }

    /// Reconciles a sender/open failure with an outstanding cancellation. A
    /// confirmed cancel may still be waiting for the scheduler's actor hop;
    /// wait for that boundary instead of misclassifying it as session loss.
    func transferEnded() async -> TransferEndDisposition {
        if let disposition = endDisposition { return disposition }
        if cancellationRequested, !remoteOpenMayExist {
            beginLocalConfirmationIfNeeded()
            return await schedulerConfirmationDisposition()
        }
        // Remote success tears down ACK waiters inside the multiplexer before
        // cancel() returns. The sender may therefore arrive here while the
        // controller's wire task is still recording that same success.
        try? await waitForWireAttemptCompletion()
        if confirmationAwaitsScheduler { return await schedulerConfirmationDisposition() }
        if let disposition = endDisposition { return disposition }
        guard cancellationRequested else {
            terminalState = .ended
            cancellationOperation = nil
            return .ordinary
        }
        terminalState = .cleanupUnverified
        cancellationOperation = nil
        resolveAttempt(.cleanupUnverified)
        resolveSendGate(.failure(AsyncActiveUploadCancellationError.cleanupUnverified))
        return .cleanupUnverified
    }

    /// Lets the scheduler distinguish an authoritative final ACK from an
    /// ordinary executor end without re-running any terminal transition.
    func currentTransferEndDisposition() -> TransferEndDisposition? {
        endDisposition
    }

    private func startWireAttemptIfPossible() {
        guard wireAttemptTask == nil,
              attemptContinuation != nil,
              !confirmationAwaitsScheduler,
              terminalState == nil,
              let cancellationOperation else { return }
        wireAttemptTask = Task { [weak self, cancellationOperation] in
            let result: Result<Void, Error>
            do {
                try await cancellationOperation()
                result = .success(())
            } catch {
                result = .failure(error)
            }
            await self?.finishWireAttempt(result)
        }
    }

    private func finishWireAttempt(_ result: Result<Void, Error>) {
        wireAttemptTask = nil
        if terminalState == nil, attemptContinuation != nil {
            switch result {
            case .success:
                confirmationAwaitsScheduler = true
                resolveAttempt(.confirmed)
            case let .failure(error):
                resolveAttempt(.failed(AsyncTransferFailureLabel.label(for: error)))
            }
        }
        resolveWireAttemptWaiters()
    }

    private func waitForWireAttemptCompletion() async throws {
        guard wireAttemptTask != nil else { return }
        let id = UUID()
        let waiter = AsyncRpcOneShot<Void>()
        wireAttemptCompletionWaiters[id] = waiter
        do {
            try await waiter.wait(cancellationPolicy: .firstResolutionWins, onCancel: {})
            wireAttemptCompletionWaiters.removeValue(forKey: id)
        } catch {
            wireAttemptCompletionWaiters.removeValue(forKey: id)
            throw error
        }
    }

    private func resolveAttempt(_ result: AttemptResult) {
        let continuation = attemptContinuation
        attemptContinuation = nil
        continuation?.resume(returning: result)
    }

    private func resolveSendGate(_ result: Result<Void, Error>) {
        let waiters = sendGateWaiters.values
        sendGateWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resolve(result)
        }
    }

    private func beginLocalConfirmationIfNeeded() {
        guard terminalState == nil, !confirmationAwaitsScheduler else { return }
        confirmationAwaitsScheduler = true
        resolveAttempt(.confirmed)
    }

    private func schedulerConfirmationDisposition() async -> TransferEndDisposition {
        do {
            try await waitForSendAdmission()
        } catch {}
        return endDisposition ?? .cleanupUnverified
    }

    private var endDisposition: TransferEndDisposition? {
        switch terminalState {
        case .cancelled: return .cancelled
        case .completed: return .finalAcknowledged
        case .ended: return .ordinary
        case .cleanupUnverified: return .cleanupUnverified
        case nil: return nil
        }
    }

    private func resolveWireAttemptWaiters() {
        let waiters = wireAttemptCompletionWaiters.values
        wireAttemptCompletionWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resolve(.success(())) }
    }

    private func result(for state: TerminalState) -> AttemptResult {
        switch state {
        case .cancelled: return .confirmed
        case .completed, .ended: return .completed
        case .cleanupUnverified: return .cleanupUnverified
        }
    }

    private func terminalResult(_ state: TerminalState) throws {
        switch state {
        case .completed, .ended:
            return
        case .cancelled:
            throw CancellationError()
        case .cleanupUnverified:
            throw AsyncActiveUploadCancellationError.cleanupUnverified
        }
    }
}

private enum AsyncActiveUploadCancellationError: Error {
    case cleanupUnverified
}

extension AsyncTransferScheduler {
    func endActiveUploadsForSession() async -> [Task<Void, Never>] {
        let uploads = activeUploadsForSessionEnd()
        for upload in uploads {
            rateExpiryState.cancel(id: upload.id)
            if await upload.controller.sessionEnded() { upload.task.cancel() }
        }
        return uploads.map(\.task)
    }

    private func activeUploadsForSessionEnd() -> [
        (id: UUID, controller: AsyncActiveUploadCancellationController, task: Task<Void, Never>)
    ] {
        let uploads: [(
            id: UUID,
            controller: AsyncActiveUploadCancellationController,
            task: Task<Void, Never>
        )] = records.compactMap { id, current in
            guard !current.activeUploadCancellationConfirmed,
                  let controller = current.activeUploadCancellationController,
                  let task = runningTasks[id] else { return nil }
            return (id: id, controller: controller, task: task)
        }
        for upload in uploads {
            guard var record = records[upload.id] else { continue }
            AsyncTransferSchedulerPolicy.markInterrupted(
                &record,
                failureDescription: AsyncActiveUploadCancellationController
                    .cleanupUnverifiedFailureDescription,
                settled: false
            )
            records[upload.id] = record
        }
        return uploads
    }

    func commitCancellationAction(
        _ action: AsyncTransferSchedulerControlAction
    ) async -> Bool {
        guard commitControlAction(action) else { return false }
        guard action.effects.contains(.requestActiveUploadCancellation),
              let controller = records[action.jobID]?
                .activeUploadCancellationController else {
            return true
        }
        return await requestActiveUploadCancellation(
            id: action.jobID,
            controller: controller,
            completedRollback: action
        )
    }

    func retryFailedActiveUploadCancellationIfNeeded(_ id: UUID) async -> Bool? {
        guard acceptsSubmissions,
              var record = records[id],
              record.state == .cleaning,
              record.failureDescription != nil,
              let controller = record.activeUploadCancellationController else {
            return nil
        }
        let previous = record
        record.failureDescription = nil
        records[id] = record
        guard persistCurrentQueue() else {
            records[id] = previous
            broadcastSnapshots()
            return false
        }
        broadcastSnapshots()
        return await requestActiveUploadCancellation(id: id, controller: controller)
    }

    func requestActiveUploadCancellation(
        id: UUID,
        controller: AsyncActiveUploadCancellationController,
        completedRollback: AsyncTransferSchedulerControlAction? = nil
    ) async -> Bool {
        let result = await controller.requestCancellation()
        guard var record = records[id],
              record.activeUploadCancellationController === controller else {
            if result == .confirmed {
                await controller.rejectSchedulerConfirmation()
            }
            return false
        }
        switch result {
        case .confirmed:
            guard acceptsSubmissions, record.state == .cleaning else {
                await controller.rejectSchedulerConfirmation()
                return false
            }
            record.activeUploadCancellationConfirmed = true
            record.failureDescription = nil
            records[id] = record
            guard persistCurrentQueue() else {
                record.activeUploadCancellationConfirmed = false
                AsyncTransferSchedulerPolicy.markInterrupted(
                    &record,
                    failureDescription: AsyncActiveUploadCancellationController
                        .cleanupUnverifiedFailureDescription,
                    settled: false
                )
                records[id] = record
                executionEnabled = false
                broadcastSnapshots()
                await controller.rejectSchedulerConfirmation()
                return false
            }
            broadcastSnapshots()
            await controller.acknowledgeSchedulerConfirmation()
            return true
        case let .failed(description):
            record.failureDescription = description
            records[id] = record
            if !persistCurrentQueue() { executionEnabled = false }
            broadcastSnapshots()
            return false
        case .completed:
            guard acceptsSubmissions,
                  record.state == .cleaning,
                  !record.activeUploadCancellationConfirmed,
                  let completedRollback else { return false }
            // The executor had already ended (or observed its final ACK) before
            // this late cancel reached the controller. Revert only this still-
            // pending admission; a reentrant finish uninstalls the controller
            // and fails the identity guard above before we can overwrite it.
            completedRollback.rollback(records: &records, queue: &queue)
            if !persistCurrentQueue() { executionEnabled = false }
            broadcastSnapshots()
            return false
        case .cleanupUnverified:
            AsyncTransferSchedulerPolicy.markInterrupted(
                &record,
                failureDescription: AsyncActiveUploadCancellationController
                    .cleanupUnverifiedFailureDescription,
                settled: false
            )
            records[id] = record
            if !persistCurrentQueue() { executionEnabled = false }
            broadcastSnapshots()
            return false
        }
    }
}

enum AsyncActiveUploadCancellationFinishPolicy {
    static func reconcile(
        _ proposedOutcome: AsyncTransferJobOutcome,
        activeUploadEndDisposition: AsyncActiveUploadCancellationController
            .TransferEndDisposition? = nil,
        with record: inout AsyncTransferSchedulerJobRecord,
        at timestamp: UInt64
    ) -> AsyncTransferSchedulerCompletionPolicy.Resolution {
        guard record.activeUploadCancellationController != nil else {
            return AsyncTransferSchedulerCompletionPolicy.reconcile(
                proposedOutcome,
                with: &record,
                at: timestamp
            )
        }
        defer { AsyncActiveUploadCancellationController.uninstall(from: &record) }
        guard record.state == .cleaning || record.state == .interrupted else {
            return AsyncTransferSchedulerCompletionPolicy.reconcile(
                proposedOutcome,
                with: &record,
                at: timestamp
            )
        }
        if record.activeUploadCancellationConfirmed {
            return .terminal(AsyncTransferSchedulerPolicy.applyTerminalOutcome(
                .cancelled,
                to: &record,
                at: timestamp
            ))
        }
        // Final publication disproves cleanup uncertainty. An ordinary end
        // likewise makes a later cleaning admission too late to replace the
        // executor's bounded outcome; session interruption stays conservative.
        if activeUploadEndDisposition == .finalAcknowledged
            || (activeUploadEndDisposition == .ordinary && record.state == .cleaning) {
            return .terminal(AsyncTransferSchedulerPolicy.applyTerminalOutcome(
                proposedOutcome,
                to: &record,
                at: timestamp
            ))
        }
        if case .success(.upload) = proposedOutcome {
            return .terminal(AsyncTransferSchedulerPolicy.applyTerminalOutcome(
                proposedOutcome,
                to: &record,
                at: timestamp
            ))
        }
        let description = AsyncActiveUploadCancellationController
            .cleanupUnverifiedFailureDescription
        AsyncTransferSchedulerPolicy.markInterrupted(
            &record,
            failureDescription: description
        )
        return .terminal(.failure(description))
    }
}
