import DroidMatchCore
import DroidMatchPresentation
import SwiftUI

struct ProductTransferQueueView: View {
    @ObservedObject var model: TransferQueueModel
    @State private var clearFailure: CompletedTransferClearFailure?

    var body: some View {
        VStack(spacing: 0) {
            queueHeader
            Divider()
            if model.items.isEmpty {
                emptyState
            } else {
                List(model.items) { item in
                    TransferQueueRow(item: item, model: model)
                }
                .listStyle(.inset)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle(AppStrings.transfers)
        .alert(item: $clearFailure) { failure in
            Alert(
                title: Text(AppStrings.completedTransfersRemain),
                message: Text(AppStrings.completedTransfersRemovalResult(
                    failure.removedCount,
                    failure.requestedCount
                )),
                dismissButton: .cancel(Text(AppStrings.dismiss))
            )
        }
    }

    private var queueHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: persistenceSymbol)
                .foregroundStyle(persistenceColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(AppStrings.secureTransfers)
                    .font(.headline)
                Text(persistenceDetail)
                    .font(.caption)
                    .foregroundStyle(persistenceColor)
            }
            Spacer()
            if !model.isPersistenceStatusKnown || model.isRetryingPersistence {
                ProgressView().controlSize(.small)
            } else if model.persistenceStatus == .writeFailed {
                Button(AppStrings.tryAgain) {
                    Task { @MainActor in await model.retryPersistence() }
                }
                .disabled(
                    model.isRetryingPersistence
                        || model.isSubmittingTransfer
                        || model.isClearingCompleted
                )
                .accessibilityHint(AppStrings.queuePersistenceFailed)
            }
            if model.completedRemovalCount > 0 || model.isClearingCompleted {
                Button {
                    Task { @MainActor in
                        guard let result = await model.clearCompleted(),
                              !result.isComplete else { return }
                        clearFailure = CompletedTransferClearFailure(result: result)
                    }
                } label: {
                    if model.isClearingCompleted {
                        ProgressView().controlSize(.small)
                    } else {
                        Label(AppStrings.clearCompleted, systemImage: "checkmark.circle")
                    }
                }
                .disabled(
                    model.isClearingCompleted
                        || model.isSubmittingTransfer
                        || !model.canPerformQueueActions
                )
                .help(AppStrings.clearCompletedDetail)
                .accessibilityLabel(AppStrings.clearCompleted)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .background(.bar)
    }

    private var persistenceDetail: String {
        if !model.isPersistenceStatusKnown || model.isRetryingPersistence {
            return AppStrings.queuePersistencePreparing
        }
        return model.persistenceStatus == .writeFailed
            ? AppStrings.queuePersistenceFailed
            : AppStrings.persistentQueueDetail
    }

    private var persistenceColor: Color {
        if !model.isPersistenceStatusKnown || model.isRetryingPersistence {
            return .orange
        }
        return model.persistenceStatus == .writeFailed ? .red : .green
    }

    private var persistenceSymbol: String {
        if !model.isPersistenceStatusKnown || model.isRetryingPersistence {
            return "clock.arrow.circlepath"
        }
        return model.persistenceStatus == .writeFailed
            ? "exclamationmark.triangle.fill"
            : "lock.shield.fill"
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(AppStrings.noTransfers)
                .font(.title3.weight(.semibold))
            Text(AppStrings.noTransfersDetail)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

private struct TransferQueueRow: View {
    let item: TransferQueuePresentationItem
    @ObservedObject var model: TransferQueueModel
    @State private var actionFailed = false

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: item.kind == .download ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                .font(.title2)
                .foregroundStyle(stateColor)
                .accessibilityLabel(item.kind == .download ? AppStrings.download : AppStrings.upload)
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(item.localFileName ?? AppStrings.unnamedItem)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    Spacer()
                    Text(stateText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(stateColor)
                }
                ProgressView(value: item.fractionCompleted)
                HStack(spacing: 10) {
                    Text(progressText)
                    if let rate = item.recentBytesPerSecond {
                        Text(AppStrings.perSecond(
                            ByteCountFormatter.string(
                                fromByteCount: Int64(rate),
                                countStyle: .file
                            )
                        ))
                    }
                    if item.attemptNumber > 1 {
                        Text(AppStrings.attempt(item.attemptNumber))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let failureGuidanceText {
                    Text(failureGuidanceText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            actionButtons
        }
        .padding(.vertical, 8)
        .alert(AppStrings.transferActionFailed, isPresented: $actionFailed) {
            Button(AppStrings.dismiss) {}
        } message: {
            Text(AppStrings.transferActionFailedDetail)
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 6) {
            if item.canPause {
                queueButton(AppStrings.pause, symbol: "pause.fill") {
                    await model.pause(item.id)
                }
            }
            if item.canResume {
                queueButton(AppStrings.resume, symbol: "play.fill") {
                    await model.resume(item.id)
                }
            }
            if item.canCancel {
                queueButton(
                    item.state == .cleaning ? AppStrings.retryCleanup : AppStrings.cancel,
                    symbol: item.state == .cleaning ? "arrow.clockwise" : "xmark"
                ) {
                    await model.cancel(item.id)
                }
            }
            if item.canRemove {
                queueButton(AppStrings.remove, symbol: "trash") {
                    await model.remove(item.id)
                }
            }
        }
        .buttonStyle(.borderless)
        .disabled(!model.canPerformQueueActions || model.isActionPending(item.id))
    }

    private func queueButton(
        _ label: String,
        symbol: String,
        action: @escaping @MainActor () async -> Bool
    ) -> some View {
        Button {
            Task { @MainActor in
                if !(await action()) {
                    actionFailed = true
                }
            }
        } label: {
            Image(systemName: symbol)
        }
        .help(label)
        .accessibilityLabel(label)
    }

    private var stateText: String {
        switch item.state {
        case .queued: return AppStrings.transferQueued
        case .running:
            return item.kind == .download
                ? AppStrings.transferRunning
                : AppStrings.transferUploading
        case .retrying: return AppStrings.transferRetrying
        case .pausing: return AppStrings.transferPausing
        case .paused: return AppStrings.transferPaused
        case .cleaning: return AppStrings.transferCleaning
        case .completed: return AppStrings.transferCompleted
        case .failed: return AppStrings.transferFailed
        case .cancelled: return AppStrings.transferCancelled
        case .interrupted: return AppStrings.transferInterrupted
        }
    }

    private var stateColor: Color {
        switch item.state {
        case .completed: return .green
        case .failed, .interrupted: return .red
        case .cancelled: return .secondary
        case .paused, .pausing, .retrying, .cleaning: return .orange
        case .queued, .running: return .blue
        }
    }

    private var progressText: String {
        let confirmed = ByteCountFormatter.string(
            fromByteCount: item.confirmedBytes,
            countStyle: .file
        )
        guard let total = item.totalBytes else { return confirmed }
        return AppStrings.progress(
            confirmed,
            ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        )
    }

    private var failureGuidanceText: String? {
        switch item.state {
        case .retrying:
            return AppStrings.transferRetryingDetail
        case .cleaning:
            return item.failureCategory == nil
                ? AppStrings.transferCleaningDetail
                : AppStrings.transferCleanupRetryDetail
        case .interrupted:
            return AppStrings.transferFailureRestartRequiredDetail
        case .failed:
            break
        case .queued, .running, .pausing, .paused, .completed, .cancelled:
            return nil
        }

        switch item.failureCategory ?? .generic {
        case .connection: return AppStrings.transferFailureConnectionDetail
        case .androidPermission: return AppStrings.transferFailureAndroidPermissionDetail
        case .remoteUnavailable: return AppStrings.transferFailureRemoteUnavailableDetail
        case .destinationConflict: return AppStrings.transferFailureDestinationConflictDetail
        case .invalidRequest: return AppStrings.transferFailureInvalidRequestDetail
        case .integrity: return AppStrings.transferFailureIntegrityDetail
        case .androidStorage: return AppStrings.transferFailureAndroidStorageDetail
        case .unsupported: return AppStrings.transferFailureUnsupportedDetail
        case .localSource: return AppStrings.transferFailureLocalSourceDetail
        case .localDestination: return AppStrings.transferFailureLocalDestinationDetail
        case .queuePersistence: return AppStrings.transferFailureQueuePersistenceDetail
        case .restartRequired: return AppStrings.transferFailureRestartRequiredDetail
        case .protocolFailure: return AppStrings.transferFailureProtocolDetail
        case .generic: return AppStrings.transferFailureGenericDetail
        }
    }
}

private struct CompletedTransferClearFailure: Identifiable {
    let id = UUID()
    let requestedCount: Int
    let removedCount: Int

    init(result: CompletedTransferRemovalResult) {
        requestedCount = result.requestedCount
        removedCount = result.removedCount
    }
}
