import Foundation
@testable import DroidMatchCore

extension LocalFrameTestServer {
    static func browserMutationResponse(
        to request: Droidmatch_V1_RpcEnvelope
    ) throws -> LocalControlPlaneResponse {
        var mutation = Droidmatch_V1_FileMutationResponse()

        switch request.payloadType {
        case .createDirectoryRequest:
            let payload = try Droidmatch_V1_CreateDirectoryRequest(serializedBytes: request.payload)
            switch payload.path {
            case "dm://app-sandbox/Reports/":
                mutation.ok = true
            case "dm://app-sandbox/denied/":
                mutation.error = browserError(.permissionRequired)
            case "dm://app-sandbox/invalid-response/":
                break
            default:
                throw LocalEchoServerError.unexpectedPayloadType
            }
        case .renamePathRequest:
            let payload = try Droidmatch_V1_RenamePathRequest(serializedBytes: request.payload)
            switch (payload.sourcePath, payload.destinationPath) {
            case (
                "dm://app-sandbox/Reports/draft.txt",
                "dm://app-sandbox/Reports/final.txt"
            ):
                mutation.ok = true
            case (
                "dm://app-sandbox/Reports/missing.txt",
                "dm://app-sandbox/Reports/final.txt"
            ):
                mutation.error = browserError(.notFound)
            default:
                throw LocalEchoServerError.unexpectedPayloadType
            }
        case .deletePathRequest:
            let payload = try Droidmatch_V1_DeletePathRequest(serializedBytes: request.payload)
            switch (payload.path, payload.recursive) {
            case ("dm://app-sandbox/Reports/", true):
                mutation.ok = true
            case ("dm://app-sandbox/read-only.txt", false):
                mutation.error = browserError(.storageReadOnly)
            default:
                throw LocalEchoServerError.unexpectedPayloadType
            }
        default:
            throw LocalEchoServerError.unexpectedPayloadType
        }

        var response = Droidmatch_V1_RpcEnvelope()
        response.frameVersion = 1
        response.kind = .response
        response.requestID = request.requestID
        response.payloadType = .fileMutationResponse
        response.payload = try mutation.serializedData()
        return LocalControlPlaneResponse(
            payloads: [try response.serializedData()],
            isFinal: false
        )
    }

    static func browserThumbnailResponse(
        to request: Droidmatch_V1_RpcEnvelope
    ) throws -> LocalControlPlaneResponse {
        let payload = try Droidmatch_V1_ThumbnailRequest(serializedBytes: request.payload)
        var thumbnail = Droidmatch_V1_ThumbnailResponse()

        switch (payload.path, payload.maxDimensionPx) {
        case ("dm://media-images/media/42", 128):
            thumbnail.encodedImage = Data([1, 2, 3])
            thumbnail.mimeType = "image/jpeg"
            thumbnail.widthPx = 128
            thumbnail.heightPx = 64
        case ("dm://media-images/albums/0123456789abcdef01234567/", 64):
            thumbnail.encodedImage = Data([4, 5, 6])
            thumbnail.mimeType = "image/png"
            thumbnail.widthPx = 64
            thumbnail.heightPx = 64
        case ("dm://media-images/media/404", 128):
            thumbnail.error = browserError(.notFound)
        case ("dm://media-images/media/43", 128):
            thumbnail.encodedImage = Data([7])
            thumbnail.mimeType = "image/jpeg"
            thumbnail.widthPx = 129
            thumbnail.heightPx = 64
        default:
            throw LocalEchoServerError.unexpectedPayloadType
        }

        var response = Droidmatch_V1_RpcEnvelope()
        response.frameVersion = 1
        response.kind = .response
        response.requestID = request.requestID
        response.payloadType = .thumbnailResponse
        response.payload = try thumbnail.serializedData()
        return LocalControlPlaneResponse(
            payloads: [try response.serializedData()],
            isFinal: false
        )
    }

    private static func browserError(
        _ code: Droidmatch_V1_ErrorCode
    ) -> Droidmatch_V1_DroidMatchError {
        var error = Droidmatch_V1_DroidMatchError()
        error.code = code
        error.message = "bounded browser fixture error"
        return error
    }
}
