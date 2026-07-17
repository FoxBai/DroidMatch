import Foundation

/// Deadline lifecycle for the single-reader RPC actor. Keeping timeout tasks
/// here separates wall-clock policy from frame routing while termination remains
/// centralized on `AsyncRpcMultiplexer`.
extension AsyncRpcMultiplexer {
    func makeTransferTimeoutTask(
        requestID: UInt64,
        direction: Droidmatch_V1_TransferDirection,
        waiter: AsyncRpcOneShot<Data>
    ) -> Task<Void, Never> {
        makeDeadlineTask { [weak self, waiter] in
            guard let self else { return }
            await self.timeoutTransferOpen(
                requestID: requestID,
                direction: direction,
                waiter: waiter
            )
        }
    }

    private func timeoutTransferOpen(
        requestID: UInt64,
        direction: Droidmatch_V1_TransferDirection,
        waiter: AsyncRpcOneShot<Data>
    ) async {
        let stillPending: Bool
        switch direction {
        case .download:
            stillPending = downloads[requestID]?.openWaiter === waiter
                && downloads[requestID]?.openResponse == nil
        case .upload:
            stillPending = uploads[requestID]?.openWaiter === waiter
                && uploads[requestID]?.openResponse == nil
        default:
            stillPending = false
        }
        guard stillPending else { return }
        await terminate(with: FramedTcpClientError.timedOut(
            stage: "waiting for transfer open response \(requestID)",
            seconds: requestTimeoutSeconds
        ))
    }

    func makeUploadAckTimeoutTask(
        requestID: UInt64,
        waiter: AsyncRpcOneShot<Droidmatch_V1_TransferChunkAck>
    ) -> Task<Void, Never> {
        makeDeadlineTask { [weak self, waiter] in
            guard let self else { return }
            await self.timeoutUploadAck(requestID: requestID, waiter: waiter)
        }
    }

    private func timeoutUploadAck(
        requestID: UInt64,
        waiter: AsyncRpcOneShot<Droidmatch_V1_TransferChunkAck>
    ) async {
        guard uploads[requestID]?.outstandingAcknowledgements.contains(where: {
            $0.waiter === waiter
        }) == true else { return }
        await terminate(with: FramedTcpClientError.timedOut(
            stage: "waiting for upload ACK \(requestID)",
            seconds: requestTimeoutSeconds
        ))
    }

    func makeTimeoutTask(
        requestID: UInt64,
        waiter: AsyncRpcOneShot<Data>
    ) -> Task<Void, Never> {
        makeDeadlineTask { [weak self, waiter] in
            guard let self else { return }
            await self.timeoutRequest(requestID: requestID, waiter: waiter)
        }
    }

    private func timeoutRequest(
        requestID: UInt64,
        waiter: AsyncRpcOneShot<Data>
    ) async {
        guard let pending = pendingResponses[requestID], pending.waiter === waiter else {
            return
        }
        await terminate(with: FramedTcpClientError.timedOut(
            stage: "waiting for RPC response \(requestID)",
            seconds: requestTimeoutSeconds
        ))
    }

    private func makeDeadlineTask(
        action: @escaping @Sendable () async -> Void
    ) -> Task<Void, Never> {
        // `start()` rejects invalid values. Keep an immediate fail-closed
        // fallback here so future call paths cannot reintroduce a conversion trap.
        let delay = AsyncTimeoutPolicy.nanoseconds(for: requestTimeoutSeconds) ?? 0
        return Task {
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return
            }
            await action()
        }
    }
}
