import Foundation

package enum PrivateAtomicFileWriterError: Error, Sendable, Equatable {
    /// The exact destination entry or its pinned parent is not safe to use.
    case unsafeDestination
    /// Publication, rollback, or recovery-node durability could not be proven.
    case commitUncertain
}
