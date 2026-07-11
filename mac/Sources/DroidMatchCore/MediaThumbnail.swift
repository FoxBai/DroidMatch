import Foundation

public struct MediaThumbnail: Sendable, Equatable {
    public let encodedImage: Data
    public let mimeType: String
    public let widthPx: UInt32
    public let heightPx: UInt32
}

public enum MediaThumbnailError: Error, Sendable, Equatable {
    case invalidRequest
    case remote(DirectoryMutationFailure)
    case invalidResponse
}

public protocol MediaThumbnailClient: Sendable {
    func thumbnail(path: String, maxDimensionPx: UInt32) async throws -> MediaThumbnail
}

public extension MediaThumbnailClient {
    func thumbnail(path: String, maxDimensionPx: UInt32) async throws -> MediaThumbnail {
        throw MediaThumbnailError.remote(.unsupported)
    }
}

extension AsyncRpcControlClient: MediaThumbnailClient {
    public func thumbnail(path: String, maxDimensionPx: UInt32) async throws -> MediaThumbnail {
        guard (path.hasPrefix("dm://media-images/media/")
                || path.hasPrefix("dm://media-videos/media/")),
              (32...512).contains(maxDimensionPx) else {
            throw MediaThumbnailError.invalidRequest
        }
        try requireReady()
        try requireCapability(.fileRead)
        var request = Droidmatch_V1_ThumbnailRequest()
        request.path = path
        request.maxDimensionPx = maxDimensionPx
        let response: Droidmatch_V1_ThumbnailResponse = try await execute(
            payload: request,
            requestPayloadType: .thumbnailRequest,
            responsePayloadType: .thumbnailResponse
        ) { payload in
            try Droidmatch_V1_ThumbnailResponse(serializedBytes: payload)
        }
        if response.hasError {
            throw MediaThumbnailError.remote(Self.thumbnailFailure(response.error.code))
        }
        guard !response.encodedImage.isEmpty,
              response.encodedImage.count <= 512 * 1024,
              response.mimeType == "image/jpeg" || response.mimeType == "image/png",
              response.widthPx > 0, response.heightPx > 0,
              response.widthPx <= maxDimensionPx,
              response.heightPx <= maxDimensionPx else {
            throw MediaThumbnailError.invalidResponse
        }
        return MediaThumbnail(
            encodedImage: response.encodedImage,
            mimeType: response.mimeType,
            widthPx: response.widthPx,
            heightPx: response.heightPx
        )
    }

    private static func thumbnailFailure(_ code: Droidmatch_V1_ErrorCode) -> DirectoryMutationFailure {
        switch code {
        case .permissionRequired, .unauthorized: return .permissionRequired
        case .notFound: return .notFound
        case .invalidArgument: return .invalidArgument
        case .unsupportedCapability, .unsupportedVersion: return .unsupported
        case .unspecified, .alreadyExists, .cancelled, .checksumMismatch,
             .storageReadOnly, .timeout, .transportLost, .internal,
             .protocolError, .UNRECOGNIZED: return .unavailable
        }
    }
}
