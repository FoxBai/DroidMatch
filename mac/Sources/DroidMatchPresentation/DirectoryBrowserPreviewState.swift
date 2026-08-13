import DroidMatchCore
import Foundation

/// Process-local identity for one preview presentation.
///
/// The random value exists only to satisfy SwiftUI's `Identifiable` contract.
/// Authorization and publication use reference identity, never a path or row ID.
final class DirectoryPreviewContextIdentity: @unchecked Sendable {
    let id = UUID()
}

/// Opaque ticket that binds one preview sheet to the model state it opened.
///
/// Callers may retain and return this value, but cannot derive a remote path or
/// authorize another preview from it.
public struct DirectoryPreviewContext: Sendable, Equatable {
    let identity: DirectoryPreviewContextIdentity

    init(identity: DirectoryPreviewContextIdentity = DirectoryPreviewContextIdentity()) {
        self.identity = identity
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.identity === rhs.identity
    }
}

/// Atomically retains the displayed row and the preview context created for it.
public struct DirectoryPreviewTarget: Identifiable, Sendable, Equatable {
    public var id: UUID { context.identity.id }
    public let item: DirectoryBrowserItem
    public let context: DirectoryPreviewContext

    init(item: DirectoryBrowserItem, context: DirectoryPreviewContext) {
        self.item = item
        self.context = context
    }
}

/// Privacy-bounded state visible only to the matching preview context.
public enum DirectoryPreviewPresentationState: Sendable, Equatable {
    case loading
    case ready(MediaThumbnail)
    case unavailable
    case invalidated
}
