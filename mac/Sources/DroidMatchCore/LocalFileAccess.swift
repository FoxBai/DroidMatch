import Foundation

/// Platform-neutral lifetime for access to one local transfer endpoint.
/// App targets may back this with a macOS security-scoped bookmark; Core never
/// serializes bookmark bytes or imports AppKit sandbox policy.
public protocol LocalFileAccessLease: Sendable {
    func release()
}

public protocol LocalFileAccessProviding: Sendable {
    /// Whether durable local authority is ready before restored work may run.
    /// Providers without persistence keep the process-local default behavior.
    func isReadyForTransferExecution() async -> Bool
    func isReadyForTransferExecution(targetURLs: Set<URL>) async -> Bool
    func acquireAccess(to url: URL) async throws -> any LocalFileAccessLease
}

public extension LocalFileAccessProviding {
    func isReadyForTransferExecution() async -> Bool { true }

    func isReadyForTransferExecution(targetURLs: Set<URL>) async -> Bool {
        _ = targetURLs
        return await isReadyForTransferExecution()
    }
}

public struct UnrestrictedLocalFileAccessProvider: LocalFileAccessProviding {
    public init() {}

    public func acquireAccess(to url: URL) async throws -> any LocalFileAccessLease {
        _ = url
        return UnrestrictedLocalFileAccessLease()
    }
}

private struct UnrestrictedLocalFileAccessLease: LocalFileAccessLease {
    func release() {}
}
