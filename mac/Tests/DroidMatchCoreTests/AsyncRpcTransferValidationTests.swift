import Foundation
import Testing
@testable import DroidMatchCore

@Test func downloadChunkValidationReturnsImmutableActorInput() throws {
    let data = Data("chunk".utf8)
    let envelope = try downloadChunkEnvelope(data: data, finalChunk: true)
    let route = downloadRoute(nextExpectedOffsetBytes: 3)
    let open = downloadOpenResponse(totalSizeBytes: 8)

    let validated = try AsyncRpcTransferValidation.validateDownloadChunk(
        envelope: envelope,
        route: route,
        open: open
    )

    #expect(validated.chunk.data == data)
    #expect(validated.chunk.offsetBytes == 3)
    #expect(validated.chunk.finalChunk)
    #expect(validated.nextOffsetBytes == 8)
    // Validation must not apply actor-owned routing state itself.
    #expect(route.nextExpectedOffsetBytes == 3)
    #expect(route.outstandingChunks.isEmpty)
}

@Test func downloadChunkValidationRejectsChecksumAndFinalSizeMismatch() throws {
    var badChecksum = try downloadChunkEnvelope(
        data: Data("chunk".utf8),
        finalChunk: true
    )
    var parsed = try Droidmatch_V1_TransferChunk(serializedBytes: badChecksum.payload)
    parsed.crc32 &+= 1
    badChecksum.payload = try parsed.serializedData()

    #expect(throws: RpcControlClientError.self) {
        try AsyncRpcTransferValidation.validateDownloadChunk(
            envelope: badChecksum,
            route: downloadRoute(nextExpectedOffsetBytes: 3),
            open: downloadOpenResponse(totalSizeBytes: 8)
        )
    }

    let wrongFinalSize = try downloadChunkEnvelope(
        data: Data("chunk".utf8),
        finalChunk: true
    )
    #expect(throws: RpcControlClientError.self) {
        try AsyncRpcTransferValidation.validateDownloadChunk(
            envelope: wrongFinalSize,
            route: downloadRoute(nextExpectedOffsetBytes: 3),
            open: downloadOpenResponse(totalSizeBytes: 9)
        )
    }
}

private func downloadChunkEnvelope(
    data: Data,
    finalChunk: Bool
) throws -> Droidmatch_V1_RpcEnvelope {
    var chunk = Droidmatch_V1_TransferChunk()
    chunk.transferID = "download-validation"
    chunk.offsetBytes = 3
    chunk.data = data
    chunk.crc32 = Crc32.checksum(data)
    chunk.finalChunk = finalChunk

    var envelope = Droidmatch_V1_RpcEnvelope()
    envelope.kind = .stream
    envelope.requestID = 7
    envelope.streamID = 17
    envelope.payloadType = .transferChunk
    envelope.payload = try chunk.serializedData()
    return envelope
}

private func downloadRoute(nextExpectedOffsetBytes: Int64) -> AsyncRpcDownloadRoute {
    var route = AsyncRpcDownloadRoute(
        requestID: 7,
        transferID: "download-validation",
        openWaiter: AsyncRpcOneShot<Data>(),
        chunkQueue: AsyncDownloadChunkQueue(capacity: 4),
        terminalState: AsyncRpcTransferTerminalState()
    )
    route.nextExpectedOffsetBytes = nextExpectedOffsetBytes
    return route
}

private func downloadOpenResponse(
    totalSizeBytes: Int64
) -> Droidmatch_V1_OpenTransferResponse {
    var response = Droidmatch_V1_OpenTransferResponse()
    response.transferID = "download-validation"
    response.streamID = 17
    response.acceptedOffsetBytes = 3
    response.chunkSizeBytes = 8
    response.totalSizeBytes = totalSizeBytes
    return response
}
