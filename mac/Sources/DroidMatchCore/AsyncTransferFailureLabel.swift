/// Privacy-bounded labels for transfer failures crossing the scheduler boundary.
///
/// Coordinator and transport errors may carry local paths, provider document
/// identifiers, or platform text. Those details are useful while debugging a
/// private session, but they must not become queue snapshots or product-facing
/// outcomes. Remote failures retain only their stable protocol code.
///
/// 中文：传输队列只保留有限、稳定的错误标签；本地路径、Provider 文本和
/// document ID 不得穿过 scheduler 边界。
enum AsyncTransferFailureLabel {
    static func label(for error: Error) -> String {
        if let rpcError = error as? RpcControlClientError,
           case let .remoteError(remoteError) = rpcError {
            return "remote error: \(String(describing: remoteError.code))"
        }
        if error is AsyncDownloadCoordinatorError {
            return "download transfer error"
        }
        if error is AsyncUploadCoordinatorError {
            return "upload transfer error"
        }
        if error is AsyncDownloadFileError {
            return "download file error"
        }
        if error is AsyncUploadFileSourceError {
            return "upload source error"
        }
        if error is FramedTcpClientError {
            return "transport error"
        }
        return "transfer error"
    }
}
