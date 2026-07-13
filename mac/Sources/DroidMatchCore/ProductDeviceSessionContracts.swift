import Foundation

public enum ProductDeviceSessionError: Error, Sendable, Equatable {
    case noPreparedDevice
    case pairingNotRequired
    case identityUnavailable
    case identityChanged
    case pairingRejected
    case credentialsUnavailable
    case authenticationFailed
    case connectionUnavailable
}

public struct ProductDeviceSessionInfo: Sendable, Equatable {
    public let deviceID: UUID
    public let displayName: String
    public let grantedCapabilities: [Droidmatch_V1_Capability]

    public init(
        deviceID: UUID,
        displayName: String,
        grantedCapabilities: [Droidmatch_V1_Capability]
    ) {
        self.deviceID = deviceID
        self.displayName = displayName
        self.grantedCapabilities = grantedCapabilities
    }
}

public enum ProductDeviceConnectionOutcome: Sendable, Equatable {
    case ready(ProductDeviceSessionInfo)
    case pairingRequired
}

public protocol ProductDeviceSessionCoordinating: ProductDeviceDiagnosticsLoading {
    func connect(to deviceID: UUID) async throws -> ProductDeviceConnectionOutcome
    func pair(
        clientDisplayName: String,
        approve: @escaping @Sendable (PairingPresentation) async throws -> Bool
    ) async throws -> ProductDeviceSessionInfo
    func directoryListingClient() async throws -> any DirectoryBrowserClient
    func transferScheduler() async throws -> AsyncTransferScheduler
    func sessionInvalidationEvents() async throws -> AsyncStream<ProductDeviceSessionEvent>
    func disconnect() async
}

/// Narrow client surface owned by the product coordinator.
///
/// Keeping this protocol separate from the concrete RPC actor makes resource
/// ownership, stale-operation rejection, and credential selection testable
/// without a live socket or Keychain.
public protocol ProductSessionClient: DirectoryBrowserClient, ProductDiagnosticsClient {
    func handshake() async throws -> HandshakeSmokeResult
    func heartbeat(monotonicMillis: Int64) async throws -> Droidmatch_V1_HeartbeatResponse
    func close() async
}

extension AsyncRpcControlClient: ProductSessionClient {}

public protocol ProductPairingClient: Sendable {
    func pair(
        clientDisplayName: String,
        approve: @escaping @Sendable (PairingPresentation) async throws -> Bool
    ) async throws -> PairingCredentialMetadata
    func close() async
}

extension AsyncPairingClient: ProductPairingClient {}
