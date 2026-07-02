import Foundation

public final class AtomicDownloadWriter {
    public let destinationURL: URL
    public let partialURL: URL
    public let requestedOffsetBytes: Int64

    private let fileManager: FileManager
    private var output: FileHandle?

    public init(
        destinationURL: URL,
        resume: Bool,
        fileManager: FileManager = .default
    ) throws {
        self.destinationURL = destinationURL
        self.partialURL = Self.partialURL(for: destinationURL)
        self.fileManager = fileManager

        try fileManager.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !resume {
            try? fileManager.removeItem(at: partialURL)
        }
        if !fileManager.fileExists(atPath: partialURL.path) {
            _ = fileManager.createFile(atPath: partialURL.path, contents: nil)
        }

        let requestedOffsetBytes = try Self.existingFileSize(at: partialURL, fileManager: fileManager)
        self.requestedOffsetBytes = requestedOffsetBytes

        let output = try FileHandle(forWritingTo: partialURL)
        try output.truncate(atOffset: UInt64(requestedOffsetBytes))
        try output.seek(toOffset: UInt64(requestedOffsetBytes))
        self.output = output
    }

    deinit {
        try? close()
    }

    public func write(_ data: Data) throws {
        guard let output else {
            throw AtomicDownloadWriterError.closed
        }
        try output.write(contentsOf: data)
    }

    public func commit() throws {
        try close()
        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(
                destinationURL,
                withItemAt: partialURL,
                backupItemName: nil,
                options: []
            )
        } else {
            try fileManager.moveItem(at: partialURL, to: destinationURL)
        }
    }

    public func close() throws {
        guard let output else {
            return
        }
        self.output = nil
        try output.close()
    }

    public static func partialURL(for destinationURL: URL) -> URL {
        URL(fileURLWithPath: destinationURL.path + ".droidmatch-part")
    }

    private static func existingFileSize(at url: URL, fileManager: FileManager) throws -> Int64 {
        guard fileManager.fileExists(atPath: url.path) else {
            return 0
        }
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let size = attributes[.size] as? NSNumber
        return size?.int64Value ?? 0
    }
}

public enum AtomicDownloadWriterError: Error, CustomStringConvertible {
    case closed

    public var description: String {
        switch self {
        case .closed:
            return "download writer is closed"
        }
    }
}
