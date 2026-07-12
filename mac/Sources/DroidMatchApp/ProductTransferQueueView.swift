import DroidMatchCore
import DroidMatchPresentation
import SwiftUI

struct ProductTransferQueueView: View {
    @ObservedObject var model: TransferQueueModel

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
    }

    private var queueHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.shield.fill")
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(AppStrings.secureTransfers)
                    .font(.headline)
                Text(model.persistenceStatus == .writeFailed
                     ? AppStrings.queuePersistenceFailed
                     : AppStrings.persistentQueueDetail)
                    .font(.caption)
                    .foregroundStyle(model.persistenceStatus == .writeFailed ? .red : .secondary)
            }
            Spacer()
            if model.persistenceStatus == .writeFailed {
                Button(AppStrings.tryAgain) {
                    Task { @MainActor in await model.retryPersistence() }
                }
                .disabled(model.isRetryingPersistence)
                .accessibilityHint(AppStrings.queuePersistenceFailed)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .background(.bar)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
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

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: item.kind == .download ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                .font(.title2)
                .foregroundStyle(stateColor)
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
            }
            actionButtons
        }
        .padding(.vertical, 8)
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
                .disabled(model.persistenceStatus == .writeFailed)
            }
            if item.canCancel {
                queueButton(AppStrings.cancel, symbol: "xmark") {
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
    }

    private func queueButton(
        _ label: String,
        symbol: String,
        action: @escaping @MainActor () async -> Void
    ) -> some View {
        Button {
            Task { @MainActor in await action() }
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
        case .paused, .pausing, .retrying: return .orange
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
}
