/// Non-authoritative wire metadata shared by product and harness upload paths.
///
/// Android authorizes an upload by `destination_path`; the inactive Mac source
/// field is diagnostic only. Keeping it opaque prevents local paths and personal
/// file names from crossing the session while local sidecars retain the real path
/// needed for source identity checks.
public enum TransferWireMetadata {
    public static let localUploadSource = "mac-local-upload"
}
