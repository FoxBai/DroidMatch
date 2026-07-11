import Foundation

/// Writes private App-owned recovery data without a permissive pre-chmod window.
///
/// The unpredictable candidate is created with `0600` in the destination
/// directory, fully written and synchronized, then atomically moved over the
/// destination. Callers remain responsible for validating their directory and
/// rejecting a symbolic-link destination before entering this boundary.
package enum PrivateAtomicFileWriter {
    package static func write(
        _ data: Data,
        to destinationURL: URL,
        fileManager: FileManager = .default
    ) throws {
        let directoryURL = destinationURL.deletingLastPathComponent()
        let candidateURL = directoryURL.appendingPathComponent(
            ".\(destinationURL.lastPathComponent).\(UUID().uuidString).tmp"
        )
        guard fileManager.createFile(
            atPath: candidateURL.path,
            contents: nil,
            attributes: [.posixPermissions: NSNumber(value: 0o600)]
        ) else {
            throw CocoaError(.fileWriteFileExists)
        }
        var candidateNeedsRemoval = true
        defer {
            if candidateNeedsRemoval {
                try? fileManager.removeItem(at: candidateURL)
            }
        }

        let handle = try FileHandle(forWritingTo: candidateURL)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }

        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(
                destinationURL,
                withItemAt: candidateURL,
                backupItemName: nil,
                options: []
            )
        } else {
            try fileManager.moveItem(at: candidateURL, to: destinationURL)
        }
        candidateNeedsRemoval = false
    }
}
