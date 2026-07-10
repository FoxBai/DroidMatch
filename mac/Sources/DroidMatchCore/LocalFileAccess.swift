import Foundation

/// Platform-neutral lifetime for access to one local transfer endpoint.
/// App targets may back this with a macOS security-scoped bookmark; Core never
/// serializes bookmark bytes or imports AppKit sandbox policy.
public protocol LocalFileAccessLease: Sendable {
    func release()
}

public protocol LocalFileAccessProviding: Sendable {
    func acquireAccess(to url: URL) async throws -> any LocalFileAccessLease
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
