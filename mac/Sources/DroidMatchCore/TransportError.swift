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
        case let .connectionFailed(message): return "connection failed: \(message)"
        case let .connectionClosed(stage): return "connection closed while \(stage)"
        }
    }
}
