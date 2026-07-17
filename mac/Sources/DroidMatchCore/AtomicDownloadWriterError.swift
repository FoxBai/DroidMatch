import Foundation

public enum AtomicDownloadWriterError: Error, CustomStringConvertible, Equatable {
    case closed
    case invalidDestination
    case unsafeDestinationDirectory
    case unsafePartialFile
    case destinationBusy
    case destinationChanged
    case checkpointRestoreFailed
    case commitUncertain

    public var description: String {
        switch self {
        case .closed:
            return "download writer is closed"
        case .invalidDestination:
            return "download destination is invalid"
        case .unsafeDestinationDirectory:
            return "download destination parent must be a non-symlink directory"
        case .unsafePartialFile:
            return "download partial must be a single-link regular file"
        case .destinationBusy:
            return "download destination is already in use"
        case .destinationChanged:
            return "download destination changed during transfer"
        case .checkpointRestoreFailed:
            return "download rollback could not restore its resume checkpoint"
        case .commitUncertain:
            return "download commit outcome is uncertain; do not retry automatically"
        }
    }
}
