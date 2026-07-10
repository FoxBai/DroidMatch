import Foundation

public enum TransferResumeRecordError: Error, CustomStringConvertible, Sendable, Equatable {
    case invalidField(String)

    public var description: String {
        switch self {
        case let .invalidField(message):
            return "invalid transfer resume record: \(message)"
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

    public static func load(from url: URL, fileManager: FileManager = .default) throws -> Self? {
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        let record = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        try record.validate()
        return record
    }

    public func save(to url: URL, fileManager: FileManager = .default) throws {
        try validate()
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }

    public static func remove(from url: URL, fileManager: FileManager = .default) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
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

/// Durable metadata required to reopen one interrupted upload.
public struct UploadResumeRecord: Codable, Equatable, Sendable {
    public let transferID: String
    public let sourcePath: String
    public let destinationPath: String
    public let totalSizeBytes: Int64
    public let sourceModifiedUnixMillis: Int64
    public let nextOffsetBytes: Int64

    public init(
        transferID: String,
        sourcePath: String,
        destinationPath: String,
        totalSizeBytes: Int64,
        sourceModifiedUnixMillis: Int64,
        nextOffsetBytes: Int64
    ) {
        self.transferID = transferID
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.totalSizeBytes = totalSizeBytes
        self.sourceModifiedUnixMillis = sourceModifiedUnixMillis
        self.nextOffsetBytes = nextOffsetBytes
    }

    public static func sidecarURL(forSource sourceURL: URL) -> URL {
        URL(fileURLWithPath: sourceURL.path + ".droidmatch-upload-transfer.json")
    }

    public static func load(from url: URL, fileManager: FileManager = .default) throws -> Self? {
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        let record = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        try record.validate()
        return record
    }

    public func save(to url: URL, fileManager: FileManager = .default) throws {
        try validate()
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }

    public static func remove(from url: URL, fileManager: FileManager = .default) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
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
    }
}
