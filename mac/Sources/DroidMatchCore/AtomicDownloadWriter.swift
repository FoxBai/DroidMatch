import Darwin
import Foundation

public final class AtomicDownloadWriter {
    public let destinationURL: URL
    public let partialURL: URL
    public let requestedOffsetBytes: Int64

    private let destinationName: String
    private let partialName: String
    private var directoryDescriptor: Int32?
    private var output: FileHandle?

    public init(
        destinationURL: URL,
        resume: Bool,
        fileManager: FileManager = .default
    ) throws {
        self.destinationURL = destinationURL
        self.partialURL = Self.partialURL(for: destinationURL)
        self.destinationName = destinationURL.lastPathComponent
        self.partialName = self.partialURL.lastPathComponent

        guard !destinationName.isEmpty,
              destinationName != ".",
              destinationName != "..",
              !partialName.isEmpty else {
            throw AtomicDownloadWriterError.invalidDestination
        }

        let directoryURL = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )

        // Pin the authorized directory for the writer lifetime. `openat` and
        // `renameat` below cannot be redirected by replacing its path while a
        // transfer is active. 中文：用目录描述符固定已授权目录，避免传输期间路径被替换。
        let directoryDescriptor = try Self.openDirectory(directoryURL)
        do {
            let partialDescriptor = try Self.openPartial(
                directoryDescriptor: directoryDescriptor,
                partialName: partialName,
                resume: resume
            )
            let output = FileHandle(
                fileDescriptor: partialDescriptor,
                closeOnDealloc: true
            )
            do {
                let sizeBytes = try Self.regularFileSize(
                    descriptor: partialDescriptor
                )
                let requestedOffsetBytes = resume ? sizeBytes : 0
                try output.seek(toOffset: UInt64(requestedOffsetBytes))

                self.requestedOffsetBytes = requestedOffsetBytes
                self.directoryDescriptor = directoryDescriptor
                self.output = output
            } catch {
                try? output.close()
                throw error
            }
        } catch {
            Darwin.close(directoryDescriptor)
            throw error
        }
    }

    deinit {
        try? close()
        closeDirectory()
    }

    public func write(_ data: Data) throws {
        guard let output else {
            throw AtomicDownloadWriterError.closed
        }
        try output.write(contentsOf: data)
    }

    public func commit() throws {
        if let output {
            // Sync the complete partial before making its name visible as the
            // destination. The directory-entry swap itself remains atomic.
            try output.synchronize()
        }
        try close()
        guard let directoryDescriptor else {
            throw AtomicDownloadWriterError.closed
        }

        let result = partialName.withCString { partialName in
            destinationName.withCString { destinationName in
                Darwin.renameat(
                    directoryDescriptor,
                    partialName,
                    directoryDescriptor,
                    destinationName
                )
            }
        }
        guard result == 0 else {
            throw Self.currentPOSIXError()
        }
        closeDirectory()
    }

    /// Stops writes but intentionally retains the pinned directory descriptor.
    /// This preserves the existing close-then-commit contract; cancellation
    /// releases the descriptor when the writer is destroyed.
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

    /// Returns the local resume boundary without mutating either destination.
    /// The product scheduler uses this value in `OpenTransferRequest`, while the
    /// eventual writer validates the accepted offset again before writing.
    public static func requestedOffsetBytes(
        for destinationURL: URL,
        resume: Bool,
        fileManager: FileManager = .default
    ) throws -> Int64 {
        guard resume else {
            return 0
        }
        return try existingRegularFileSize(
            at: partialURL(for: destinationURL),
            fileManager: fileManager
        )
    }

    private static func existingRegularFileSize(
        at url: URL,
        fileManager: FileManager
    ) throws -> Int64 {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try fileManager.attributesOfItem(atPath: url.path)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return 0
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber,
              size.int64Value >= 0 else {
            throw AtomicDownloadWriterError.unsafePartialFile
        }
        return size.int64Value
    }

    private static func openDirectory(_ directoryURL: URL) throws -> Int32 {
        let descriptor = Darwin.open(
            directoryURL.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw currentPOSIXError()
        }
        return descriptor
    }

    private static func openPartial(
        directoryDescriptor: Int32,
        partialName: String,
        resume: Bool
    ) throws -> Int32 {
        var flags = O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW
        if !resume {
            flags |= O_TRUNC
        }
        let descriptor = partialName.withCString { partialName in
            Darwin.openat(
                directoryDescriptor,
                partialName,
                flags,
                mode_t(0o666)
            )
        }
        guard descriptor >= 0 else {
            if errno == ELOOP {
                throw AtomicDownloadWriterError.unsafePartialFile
            }
            throw currentPOSIXError()
        }
        return descriptor
    }

    private static func regularFileSize(descriptor: Int32) throws -> Int64 {
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else {
            throw currentPOSIXError()
        }
        guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              metadata.st_size >= 0 else {
            throw AtomicDownloadWriterError.unsafePartialFile
        }
        return metadata.st_size
    }

    private func closeDirectory() {
        guard let directoryDescriptor else {
            return
        }
        self.directoryDescriptor = nil
        Darwin.close(directoryDescriptor)
    }

    private static func currentPOSIXError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

public enum AtomicDownloadWriterError: Error, CustomStringConvertible {
    case closed
    case invalidDestination
    case unsafePartialFile

    public var description: String {
        switch self {
        case .closed:
            return "download writer is closed"
        case .invalidDestination:
            return "download destination is invalid"
        case .unsafePartialFile:
            return "download partial must be a regular file"
        }
    }
}
