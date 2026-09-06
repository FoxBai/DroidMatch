import Foundation

extension AsyncRpcControlClient {
    public func listApplications(query: ApplicationLibraryQuery, pageToken: String?) async throws
        -> ApplicationLibraryPage {
        try requireReady()
        try requireAuthenticatedSession()
        do { try requireCapability(.applicationList) }
        catch { throw ApplicationLibraryError.unsupported }
        let request = try ApplicationLibraryCodec.request(query: query, pageToken: pageToken)
        do {
            let response = try await execute(payload: request,
                requestPayloadType: .listApplicationsRequest,
                responsePayloadType: .listApplicationsResponse,
                cancellationSafety: .drainReadOnlyResponse) { payload in
                    try ApplicationLibraryCodec.response(payload, pageSize: query.pageSize,
                                                         requestedToken: pageToken)
                }
            return try ApplicationLibraryCodec.page(response)
        } catch let RpcControlClientError.remoteError(error) {
            throw ApplicationLibraryCodec.failure(error.code)
        }
    }
}
