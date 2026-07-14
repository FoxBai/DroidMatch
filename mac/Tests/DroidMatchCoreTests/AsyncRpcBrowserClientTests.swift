import Foundation
import Testing
@testable import DroidMatchCore

@Test func asyncRpcBrowserClientSerializesMutationsAndThumbnails() async throws {
    try await withBrowserClient(capabilities: [.fileRead, .fileWrite]) { client in
        try await client.createDirectory(path: "dm://app-sandbox/Reports/")
        try await client.renamePath(
            sourcePath: "dm://app-sandbox/Reports/draft.txt",
            destinationPath: "dm://app-sandbox/Reports/final.txt"
        )
        try await client.deletePath("dm://app-sandbox/Reports/", recursive: true)

        let item = try await client.thumbnail(
            path: "dm://media-images/media/42",
            maxDimensionPx: 128
        )
        #expect(item.encodedImage == Data([1, 2, 3]))
        #expect(item.mimeType == "image/jpeg")
        #expect(item.widthPx == 128)
        #expect(item.heightPx == 64)

        let album = try await client.thumbnail(
            path: "dm://media-images/albums/0123456789abcdef01234567/",
            maxDimensionPx: 64
        )
        #expect(album.encodedImage == Data([4, 5, 6]))
        #expect(album.mimeType == "image/png")
        #expect(album.widthPx == 64)
        #expect(album.heightPx == 64)
    }
}

@Test func asyncRpcBrowserClientMapsEmbeddedErrorsAndInvalidResponses() async throws {
    try await withBrowserClient(capabilities: [.fileRead, .fileWrite]) { client in
        await #expect(throws: DirectoryMutationError.remote(.permissionRequired)) {
            try await client.createDirectory(path: "dm://app-sandbox/denied/")
        }
        await #expect(throws: DirectoryMutationError.remote(.notFound)) {
            try await client.renamePath(
                sourcePath: "dm://app-sandbox/Reports/missing.txt",
                destinationPath: "dm://app-sandbox/Reports/final.txt"
            )
        }
        await #expect(throws: DirectoryMutationError.remote(.unavailable)) {
            try await client.deletePath("dm://app-sandbox/read-only.txt", recursive: false)
        }
        await #expect(throws: DirectoryMutationError.invalidResponse) {
            try await client.createDirectory(path: "dm://app-sandbox/invalid-response/")
        }
        await #expect(throws: MediaThumbnailError.remote(.notFound)) {
            _ = try await client.thumbnail(
                path: "dm://media-images/media/404",
                maxDimensionPx: 128
            )
        }
        await #expect(throws: MediaThumbnailError.invalidResponse) {
            _ = try await client.thumbnail(
                path: "dm://media-images/media/43",
                maxDimensionPx: 128
            )
        }

        // Embedded provider failures are request failures, not session failures.
        // 中文：provider 内嵌错误不得误关闭仍可复用的认证 RPC 会话。
        let heartbeat = try await client.heartbeat(monotonicMillis: 77)
        #expect(heartbeat.monotonicMillis == 77)
    }
}

@Test func asyncRpcBrowserClientRejectsInvalidPathsBeforeWriting() async throws {
    try await withBrowserClient(capabilities: [.fileRead, .fileWrite]) { client in
        await #expect(throws: DirectoryMutationError.invalidPath) {
            try await client.renamePath(
                sourcePath: "dm://",
                destinationPath: "dm://app-sandbox/final.txt"
            )
        }
        await #expect(throws: DirectoryMutationError.invalidPath) {
            try await client.renamePath(
                sourcePath: "dm://app-sandbox/source.txt",
                destinationPath: "dm://"
            )
        }
        for path in [
            "dm://media-images/media/",
            "dm://media-images/media/not-a-number",
            "dm://media-videos/media/-1",
            "dm://media-images/media/9223372036854775808",
        ] {
            await #expect(throws: MediaThumbnailError.invalidRequest) {
                _ = try await client.thumbnail(path: path, maxDimensionPx: 128)
            }
        }
        await #expect(throws: MediaThumbnailError.invalidRequest) {
            _ = try await client.thumbnail(
                path: "dm://media-images/media/42",
                maxDimensionPx: 31
            )
        }

        let heartbeat = try await client.heartbeat(monotonicMillis: 88)
        #expect(heartbeat.monotonicMillis == 88)
    }
}

@Test func asyncRpcBrowserClientRequiresNegotiatedCapabilities() async throws {
    try await withBrowserClient(capabilities: [.diagnostics]) { client in
        await #expect(throws: RpcControlClientError.self) {
            try await client.createDirectory(path: "dm://app-sandbox/Reports/")
        }
        await #expect(throws: RpcControlClientError.self) {
            _ = try await client.thumbnail(
                path: "dm://media-images/media/42",
                maxDimensionPx: 128
            )
        }

        let heartbeat = try await client.heartbeat(monotonicMillis: 99)
        #expect(heartbeat.monotonicMillis == 99)
    }
}

private func withBrowserClient(
    capabilities: [Droidmatch_V1_Capability],
    operation: @escaping @Sendable (AsyncRpcControlClient) async throws -> Void
) async throws {
    let server = try LocalFrameTestServer(handler: LocalFrameTestServer.replyToM1SmokeRequests)
    defer { server.cancel() }
    let session = try await AsyncFramedTcpSession.connect(port: server.port, timeoutSeconds: 2)
    let client = AsyncRpcControlClient(
        session: session,
        requestedCapabilities: capabilities
    )
    do {
        let handshake = try await client.handshake()
        #expect(handshake.grantedCapabilities == capabilities)
        try await operation(client)
        await client.close()
    } catch {
        await client.close()
        throw error
    }
}
