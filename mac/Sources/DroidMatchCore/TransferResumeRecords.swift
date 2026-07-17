import Darwin
import Foundation

public enum TransferResumeRecordError: Error, CustomStringConvertible, Sendable, Equatable {
    case invalidField(String)
    case unsafeArtifact
    case commitUncertain

    public var description: String {
        switch self {
        case let .invalidField(message):
            return "invalid transfer resume record: \(message)"
        case .unsafeArtifact:
            return "transfer resume artifact must be a single-link regular file"
        case .commitUncertain:
            return "transfer resume artifact commit state is uncertain"
        }
    }
}

/// Reads, publishes, and removes only one expected regular-file entry.
///
/// Resume artifacts live beside user-selected files and therefore remain
/// untrusted even though DroidMatch chose their names. The caller-authorized
/// parent is resolved once and pinned; `unlinkat` without `AT_REMOVEDIR` then
/// ensures an unexpected child directory is never traversed recursively and a
/// child symbolic link is never followed. A second hard link is rejected so
/// checkpoint I/O cannot consume or replace an alias whose ownership is
/// ambiguous.
enum TransferResumeArtifact {
    private static let maximumRecordBytes = 1_048_576

    static func loadRegularSingleLinkIfPresent(
        at url: URL,
        expectedDirectoryIdentity: LocalDirectoryIdentity? = nil,
        directoryContext: LocalDownloadDirectoryContext? = nil
    ) throws -> Data? {
        try mapAtomicError {
            try PrivateAtomicFileWriter.readRegularSingleLinkIfPresent(
                at: url,
                maximumBytes: maximumRecordBytes,
                requiresPrivatePermissions: true,
                expectedDirectoryIdentity: expectedDirectoryIdentity,
                directoryContext: directoryContext
            )
        }
    }

    static func saveRegularSingleLink(
        _ data: Data,
        at url: URL,
        fileManager: FileManager,
        expectedDirectoryIdentity: LocalDirectoryIdentity? = nil,
        directoryContext: LocalDownloadDirectoryContext? = nil
    ) throws {
        guard data.count <= maximumRecordBytes else {
            throw TransferResumeRecordError.invalidField(
                "resume artifact exceeds the size limit"
            )
        }
        if directoryContext == nil {
            let directoryDescriptor: Int32
            do {
                directoryDescriptor = try SafeDirectoryDescriptor.openAbsolute(
                    url.deletingLastPathComponent(),
                    createIntermediateDirectories: expectedDirectoryIdentity == nil
                )
            } catch is SafeDirectoryDescriptorError {
                throw TransferResumeRecordError.unsafeArtifact
            }
            if let expectedDirectoryIdentity {
                var metadata = stat()
                guard Darwin.fstat(directoryDescriptor, &metadata) == 0,
                      LocalDirectoryIdentity(metadata) == expectedDirectoryIdentity else {
                    Darwin.close(directoryDescriptor)
                    throw TransferResumeRecordError.unsafeArtifact
                }
            }
            Darwin.close(directoryDescriptor)
        }
        try mapAtomicError {
            try PrivateAtomicFileWriter.write(
                data,
                to: url,
                fileManager: fileManager,
                requiresPrivatePermissions: true,
                expectedDirectoryIdentity: expectedDirectoryIdentity,
                directoryContext: directoryContext
            )
        }
    }

    static func removeRegularSingleLinkIfPresent(
        at url: URL,
        expectedDirectoryIdentity: LocalDirectoryIdentity? = nil,
        directoryContext: LocalDownloadDirectoryContext? = nil
    ) throws {
        try mapAtomicError {
            try PrivateAtomicFileWriter.removeRegularSingleLinkIfPresent(
                at: url,
                requiresPrivatePermissions: true,
                expectedDirectoryIdentity: expectedDirectoryIdentity,
                directoryContext: directoryContext
            )
        }
    }

    private static func mapAtomicError<Result>(
        _ operation: () throws -> Result
    ) throws -> Result {
        do {
            return try operation()
        } catch PrivateAtomicFileWriterError.unsafeDestination {
            throw TransferResumeRecordError.unsafeArtifact
        } catch PrivateAtomicFileWriterError.commitUncertain {
            throw TransferResumeRecordError.commitUncertain
        }
    }
}

/// Codable representation of the source identity accepted by Android.
/// Coding keys intentionally retain the legacy harness camelCase JSON format.
public struct TransferFingerprintRecord: Codable, Equatable, Sendable {
    public let sizeBytes: Int64
    public let modifiedUnixMillis: Int64
    public let providerEtag: String
    public let sha256: String

    public init(_ fingerprint: Droidmatch_V1_TransferFingerprint) {
        sizeBytes = fingerprint.sizeBytes
        modifiedUnixMillis = fingerprint.modifiedUnixMillis
        providerEtag = fingerprint.providerEtag
        sha256 = fingerprint.sha256
    }

    public var proto: Droidmatch_V1_TransferFingerprint {
        var fingerprint = Droidmatch_V1_TransferFingerprint()
        fingerprint.sizeBytes = sizeBytes
        fingerprint.modifiedUnixMillis = modifiedUnixMillis
        fingerprint.providerEtag = providerEtag
        fingerprint.sha256 = sha256
        return fingerprint
    }

    fileprivate func validate() throws {
        guard sizeBytes >= -1 else {
            throw TransferResumeRecordError.invalidField(
                "fingerprint sizeBytes must be at least -1"
            )
        }
        guard modifiedUnixMillis >= 0 else {
            throw TransferResumeRecordError.invalidField(
                "fingerprint modifiedUnixMillis must be non-negative"
            )
        }
    }
}

/// Durable metadata required to reopen one interrupted download.
public struct DownloadResumeRecord: Codable, Equatable, Sendable {
    public let transferID: String
    public let sourcePath: String
    public let totalSizeBytes: Int64
    public let fingerprint: TransferFingerprintRecord

    public init(
        transferID: String,
        sourcePath: String,
        totalSizeBytes: Int64,
        fingerprint: TransferFingerprintRecord
    ) {
        self.transferID = transferID
        self.sourcePath = sourcePath
        self.totalSizeBytes = totalSizeBytes
        self.fingerprint = fingerprint
    }

    public static func sidecarURL(forDestination destinationURL: URL) -> URL {
        URL(fileURLWithPath: destinationURL.path + ".droidmatch-transfer.json")
    }

    public static func load(
        from url: URL,
        fileManager _: FileManager = .default,
        expectedDirectoryIdentity: LocalDirectoryIdentity? = nil,
        directoryContext: LocalDownloadDirectoryContext? = nil
    ) throws -> Self? {
        guard let data = try TransferResumeArtifact.loadRegularSingleLinkIfPresent(
            at: url,
            expectedDirectoryIdentity: expectedDirectoryIdentity,
            directoryContext: directoryContext
        ) else {
            return nil
        }
        let record = try JSONDecoder().decode(Self.self, from: data)
        try record.validate()
        return record
    }

    public func save(
        to url: URL,
        fileManager: FileManager = .default,
        expectedDirectoryIdentity: LocalDirectoryIdentity? = nil,
        directoryContext: LocalDownloadDirectoryContext? = nil
    ) throws {
        try validate()
        try TransferResumeArtifact.saveRegularSingleLink(
            JSONEncoder().encode(self),
            at: url,
            fileManager: fileManager,
            expectedDirectoryIdentity: expectedDirectoryIdentity,
            directoryContext: directoryContext
        )
    }

    public static func remove(
        from url: URL,
        fileManager _: FileManager = .default,
        expectedDirectoryIdentity: LocalDirectoryIdentity? = nil,
        directoryContext: LocalDownloadDirectoryContext? = nil
    ) throws {
        try TransferResumeArtifact.removeRegularSingleLinkIfPresent(
            at: url,
            expectedDirectoryIdentity: expectedDirectoryIdentity,
            directoryContext: directoryContext
        )
    }

    private func validate() throws {
        guard !transferID.isEmpty else {
            throw TransferResumeRecordError.invalidField("transferID must be non-empty")
        }
        guard !sourcePath.isEmpty else {
            throw TransferResumeRecordError.invalidField("sourcePath must be non-empty")
        }
        guard totalSizeBytes >= -1 else {
            throw TransferResumeRecordError.invalidField(
                "totalSizeBytes must be at least -1"
            )
        }
        try fingerprint.validate()
    }
}

/// Exact local file identity persisted for a resumable upload.
public struct UploadSourceIdentityRecord: Codable, Equatable, Sendable {
    public let sizeBytes: Int64
    public let modifiedUnixNanoseconds: Int64
    public let changedUnixNanoseconds: Int64
    public let fileSystemNumber: UInt64
    public let fileNumber: UInt64

    public init(_ snapshot: UploadSourceSnapshot) {
        sizeBytes = snapshot.sizeBytes
        modifiedUnixNanoseconds = snapshot.modifiedUnixNanoseconds
        changedUnixNanoseconds = snapshot.changedUnixNanoseconds
        fileSystemNumber = snapshot.fileSystemNumber
        fileNumber = snapshot.fileNumber
    }

    public func matches(_ snapshot: UploadSourceSnapshot) -> Bool {
        self == UploadSourceIdentityRecord(snapshot)
    }

    fileprivate func validate() throws {
        guard sizeBytes >= 0 else {
            throw TransferResumeRecordError.invalidField(
                "upload source identity size must be non-negative"
            )
        }
        guard modifiedUnixNanoseconds >= 0, changedUnixNanoseconds >= 0 else {
            throw TransferResumeRecordError.invalidField(
                "upload source identity timestamps must be non-negative"
            )
        }
    }
}

/// Durable metadata required to reopen one interrupted upload.
///
/// Version 1 records are decoded only for a fail-closed migration decision.
/// Every newly written checkpoint is version 2 and carries an exact source
/// identity, so a remote partial can never be continued from a replacement
/// source that happens to share its size and millisecond modification time.
public struct UploadResumeRecord: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 2

    public let formatVersion: Int
    public let transferID: String
    public let sourcePath: String
    public let destinationPath: String
    public let totalSizeBytes: Int64
    public let sourceModifiedUnixMillis: Int64
    public let sourceIdentity: UploadSourceIdentityRecord?
    public let nextOffsetBytes: Int64

    /// Constructs a current, strongly bound upload checkpoint.
    public init(
        transferID: String,
        sourcePath: String,
        destinationPath: String,
        sourceIdentity: UploadSourceIdentityRecord,
        nextOffsetBytes: Int64
    ) {
        formatVersion = Self.currentFormatVersion
        self.transferID = transferID
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        totalSizeBytes = sourceIdentity.sizeBytes
        sourceModifiedUnixMillis = sourceIdentity.modifiedUnixNanoseconds / 1_000_000
        self.sourceIdentity = sourceIdentity
        self.nextOffsetBytes = nextOffsetBytes
    }

    /// Compatibility constructor used to decode and test pre-v2 checkpoints.
    /// Production code must use the source-identity initializer above.
    public init(
        transferID: String,
        sourcePath: String,
        destinationPath: String,
        totalSizeBytes: Int64,
        sourceModifiedUnixMillis: Int64,
        nextOffsetBytes: Int64
    ) {
        formatVersion = 1
        self.transferID = transferID
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.totalSizeBytes = totalSizeBytes
        self.sourceModifiedUnixMillis = sourceModifiedUnixMillis
        sourceIdentity = nil
        self.nextOffsetBytes = nextOffsetBytes
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion
        case transferID
        case sourcePath
        case destinationPath
        case totalSizeBytes
        case sourceModifiedUnixMillis
        case sourceIdentity
        case nextOffsetBytes
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try values.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
        transferID = try values.decode(String.self, forKey: .transferID)
        sourcePath = try values.decode(String.self, forKey: .sourcePath)
        destinationPath = try values.decode(String.self, forKey: .destinationPath)
        totalSizeBytes = try values.decode(Int64.self, forKey: .totalSizeBytes)
        sourceModifiedUnixMillis = try values.decode(
            Int64.self,
            forKey: .sourceModifiedUnixMillis
        )
        sourceIdentity = try values.decodeIfPresent(
            UploadSourceIdentityRecord.self,
            forKey: .sourceIdentity
        )
        nextOffsetBytes = try values.decode(Int64.self, forKey: .nextOffsetBytes)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(formatVersion, forKey: .formatVersion)
        try values.encode(transferID, forKey: .transferID)
        try values.encode(sourcePath, forKey: .sourcePath)
        try values.encode(destinationPath, forKey: .destinationPath)
        try values.encode(totalSizeBytes, forKey: .totalSizeBytes)
        try values.encode(sourceModifiedUnixMillis, forKey: .sourceModifiedUnixMillis)
        try values.encodeIfPresent(sourceIdentity, forKey: .sourceIdentity)
        try values.encode(nextOffsetBytes, forKey: .nextOffsetBytes)
    }

    public static func sidecarURL(forSource sourceURL: URL) -> URL {
        URL(fileURLWithPath: sourceURL.path + ".droidmatch-upload-transfer.json")
    }

    public static func load(from url: URL, fileManager _: FileManager = .default) throws -> Self? {
        guard let data = try TransferResumeArtifact.loadRegularSingleLinkIfPresent(at: url) else {
            return nil
        }
        let record = try JSONDecoder().decode(Self.self, from: data)
        try record.validate()
        return record
    }

    public func save(to url: URL, fileManager: FileManager = .default) throws {
        try validate()
        try TransferResumeArtifact.saveRegularSingleLink(
            JSONEncoder().encode(self),
            at: url,
            fileManager: fileManager
        )
    }

    public static func remove(from url: URL, fileManager _: FileManager = .default) throws {
        try TransferResumeArtifact.removeRegularSingleLinkIfPresent(at: url)
    }

    private func validate() throws {
        guard !transferID.isEmpty else {
            throw TransferResumeRecordError.invalidField("transferID must be non-empty")
        }
        guard !sourcePath.isEmpty else {
            throw TransferResumeRecordError.invalidField("sourcePath must be non-empty")
        }
        guard !destinationPath.isEmpty else {
            throw TransferResumeRecordError.invalidField("destinationPath must be non-empty")
        }
        guard totalSizeBytes >= 0 else {
            throw TransferResumeRecordError.invalidField(
                "upload totalSizeBytes must be non-negative"
            )
        }
        guard sourceModifiedUnixMillis >= 0 else {
            throw TransferResumeRecordError.invalidField(
                "sourceModifiedUnixMillis must be non-negative"
            )
        }
        guard nextOffsetBytes >= 0, nextOffsetBytes <= totalSizeBytes else {
            throw TransferResumeRecordError.invalidField(
                "nextOffsetBytes must be within the source size"
            )
        }
        switch formatVersion {
        case 1:
            guard sourceIdentity == nil else {
                throw TransferResumeRecordError.invalidField(
                    "legacy upload record must not contain a strong identity"
                )
            }
        case Self.currentFormatVersion:
            guard let sourceIdentity else {
                throw TransferResumeRecordError.invalidField(
                    "current upload record requires a strong source identity"
                )
            }
            try sourceIdentity.validate()
            guard totalSizeBytes == sourceIdentity.sizeBytes,
                  sourceModifiedUnixMillis
                    == sourceIdentity.modifiedUnixNanoseconds / 1_000_000 else {
                throw TransferResumeRecordError.invalidField(
                    "upload source identity conflicts with legacy metadata"
                )
            }
        default:
            throw TransferResumeRecordError.invalidField(
                "unsupported upload resume record version"
            )
        }
    }
}
