import Foundation

/// Stable transport failures shared by the async session and recovery policy.
/// The type name remains stable for compatibility with archived diagnostics.
public enum FramedTcpClientError: Error, CustomStringConvertible, Sendable {
    case invalidPort(Int)
    case timedOut(stage: String, seconds: TimeInterval)
    case connectionFailed(String)
    case connectionClosed(stage: String)

    public var description: String {
        switch self {
        case let .invalidPort(port): return "invalid TCP port: \(port)"
        case let .timedOut(stage, seconds): return "\(stage) timed out after \(seconds)s"
        case .connectionFailed: return "connection failed"
        case let .connectionClosed(stage): return "connection closed while \(stage)"
        }
    }
}

extension FramedTcpClientError {
    /// The Network.framework callback may carry platform text that is not safe
    /// to publish (for example a private endpoint or an OS-specific detail).
    /// Keep the associated string for source compatibility, but create all
    /// session failures through this bounded label.
    static var networkFailure: Self {
        .connectionFailed("network failure")
    }
}
