import DroidMatchCore

/// Bounds direct harness diagnostics to stable labels instead of raw paths or
/// exception text. Device scripts may add their own evidence fields, but a
/// direct CLI invocation must be safe before any outer redaction pass.
/// 中文：将 harness 诊断限制为稳定标签，不直接输出路径或异常原文；外层设备脚本可补充证据字段，但直接 CLI 调用本身也必须安全。
enum HarnessPrivacy {
    static let redactedPath = "<path-redacted>"
    static let redactedName = "<name-redacted>"
    static let redactedMessage = "<message-redacted>"

    static func path(_: String) -> String {
        return redactedPath
    }

    static func message(_: String) -> String {
        return redactedMessage
    }

    static func errorLabel(_ error: Error) -> String {
        if let harnessError = error as? HarnessError {
            return harnessError.description
        }
        if let rpcError = error as? RpcControlClientError {
            switch rpcError {
            case let .remoteError(remoteError):
                // Preserve the stable wire code for operator diagnosis while
                // discarding the provider message, which may contain paths,
                // document IDs, or user file names.
                return "remote error: \(String(describing: remoteError.code))"
            default:
                return "<error:RpcControlClientError>"
            }
        }
        if let mutationError = error as? DirectoryMutationError {
            switch mutationError {
            case .invalidPath:
                return "invalid mutation path"
            case let .remote(failure):
                return "remote mutation error: \(failure.rawValue)"
            case .invalidResponse:
                return "invalid mutation response"
            }
        }
        let typeName = String(reflecting: type(of: error))
            .split(separator: ".")
            .last
            .map(String.init) ?? "Error"
        return "<error:\(typeName)>"
    }
}
