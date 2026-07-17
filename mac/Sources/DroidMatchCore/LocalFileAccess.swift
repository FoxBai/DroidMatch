import Foundation

/// Platform-neutral lifetime for access to one local transfer endpoint.
/// App targets may back this with a macOS security-scoped bookmark; Core never
/// serializes bookmark bytes or imports AppKit sandbox policy.
public protocol LocalFileAccessLease: Sendable {
    func release()
}

/// Optional package-only detail carried by bookmark-backed leases. Download
/// admission uses the resolved authorization object so a directory bookmark
/// that followed a Finder rename still pins the directory the user selected.
package protocol ResolvedLocalFileAccessLease: LocalFileAccessLease {
    var resolvedAccessURL: URL? { get }
}

public protocol LocalFileAccessProviding: Sendable {
    /// Whether durable local authority is ready before restored work may run.
    /// Providers without persistence keep the process-local default behavior.
    func isReadyForTransferExecution() async -> Bool
    func isReadyForTransferExecution(targetURLs: Set<URL>) async -> Bool
    /// Serializes the complete held-restore transaction with platform-owned
    /// authorization mutations. Persistent providers use this boundary around
    /// manifest reload, target validation, and scheduler activation.
    func withTransferExecutionPreparation<Result: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Result
    ) async throws -> Result
    func acquireAccess(to url: URL) async throws -> any LocalFileAccessLease
    func acquireDownloadDestination(
        to url: URL
    ) async throws -> any LocalDownloadDestinationLease
}

public extension LocalFileAccessProviding {
    func isReadyForTransferExecution() async -> Bool { true }

    func isReadyForTransferExecution(targetURLs: Set<URL>) async -> Bool {
        _ = targetURLs
        return await isReadyForTransferExecution()
    }

    func withTransferExecutionPreparation<Result: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Result
    ) async throws -> Result {
        try await operation()
    }

    func acquireDownloadDestination(
        to url: URL
    ) async throws -> any LocalDownloadDestinationLease {
        let accessLease = try await acquireAccess(to: url)
        return try DownloadDestinationReservation.acquire(
            destinationURL: url,
            accessLease: accessLease
        )
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
