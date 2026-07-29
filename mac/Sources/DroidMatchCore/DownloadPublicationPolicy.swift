/// Controls whether a completed download may replace the destination captured
/// when its writer is created.
///
/// Product file-browser downloads use `mustBeAbsent`: the native panel's early
/// existence check is only advisory, so the writer repeats it at acquisition
/// and again at commit. Explicit harness and internal callers may continue to
/// opt into replacement.
public enum DownloadPublicationPolicy: String, Codable, Sendable, Equatable {
    case mustBeAbsent
    case replaceExisting
}
