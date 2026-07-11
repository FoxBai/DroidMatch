import DroidMatchCore
import Foundation

public struct TransferCompletionEvent: Equatable, Sendable {
    public let id: UUID
    public let kind: AsyncTransferJobKind
    public let state: AsyncTransferJobState
    public let localFileName: String?
}

/// Pure transition policy for optional product notifications.
///
/// New terminal history is deliberately ignored: reconnecting or opening the
/// App must not replay old notifications. User-initiated cancellation is also
/// excluded, while failure and interrupted recovery state remain actionable.
public enum TransferCompletionPolicy {
    public static func events(
        previousStates: [UUID: AsyncTransferJobState],
        currentItems: [TransferQueuePresentationItem]
    ) -> [TransferCompletionEvent] {
        currentItems.compactMap { item in
            guard let previous = previousStates[item.id],
                  !previous.isTerminal,
                  item.state == .completed
                    || item.state == .failed
                    || item.state == .interrupted else {
                return nil
            }
            return TransferCompletionEvent(
                id: item.id,
                kind: item.kind,
                state: item.state,
                localFileName: item.localFileName
            )
        }
    }

    public static func states(
        for items: [TransferQueuePresentationItem]
    ) -> [UUID: AsyncTransferJobState] {
        Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.state) })
    }
}
