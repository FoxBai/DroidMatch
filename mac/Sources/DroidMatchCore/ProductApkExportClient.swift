import CryptoKit
import Foundation

/// A fresh authenticated connection owns a complete export. The ordinary queue
/// never persists session-only package tokens or resumes a changed installed set.
actor ProductApkExportClient: ApkExportClient {
    private let gate: ProductTransferSessionGate
    private var active = true
    private var exporting = false
    private var client: AsyncRpcControlClient?

    init(gate: ProductTransferSessionGate) { self.gate = gate }

    func exportApk(packageIdentifier: String, directoryURL: URL,
                   progress: @escaping @Sendable (ApkExportProgress) async -> Void) async throws -> ApkExportResult {
        try requireActive()
        guard !exporting else { throw ApkExportError.busy }
        guard directoryURL.isFileURL, ApplicationLibraryCodec.validIdentifier(packageIdentifier) else {
            throw ApkExportError.localFileFailed
        }
        exporting = true
        defer { exporting = false }
        await progress(.init(stage: .preparing, completedBytes: 0, totalBytes: 0))
        let connected = try await gate.makeClient(attemptIndex: 0)
        guard active && !Task.isCancelled else { await connected.close(); throw CancellationError() }
        client = connected
        do {
            let result = try await withTaskCancellationHandler {
                _ = try await connected.handshake()
                try requireActive()
                let manifest = try await connected.prepareApkExport(identifier: packageIdentifier)
                try requireActive()
                return try await receive(manifest, from: connected, into: directoryURL, progress: progress)
            } onCancel: { Task { await connected.close() } }
            await connected.close(); client = nil
            // Once atomic publication succeeds, a late cancel cannot undo it or
            // truthfully turn the completed file into a failed transfer.
            return result
        } catch {
            await connected.close(); client = nil
            if error as? ApkExportError == .commitUncertain { throw ApkExportError.commitUncertain }
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            if let failure = error as? ApkExportError { throw failure }
            if case RpcControlClientError.remoteError(let remote) = error { throw ApkExportCodec.failure(remote.code) }
            throw ApkExportError.connectionUnavailable
        }
    }

    func invalidate() async {
        active = false
        await gate.invalidate()
        await client?.close()
        client = nil
    }

    private func receive(_ manifest: ApkExportManifest, from client: AsyncRpcControlClient, into directory: URL,
                         progress: @escaping @Sendable (ApkExportProgress) async -> Void) async throws -> ApkExportResult {
        let isSplit = manifest.components.count > 1
        let filename = String(manifest.packageIdentifier.prefix(120)) + "-"
            + UUID().uuidString.lowercased() + (isSplit ? "-apks.zip" : ".apk")
        let destination = directory.appendingPathComponent(filename, isDirectory: false)
        let reserved: ReservedAsyncDownloadWriter
        do { reserved = try await .acquire(destinationURL: destination, resume: false, publicationPolicy: .mustBeAbsent) }
        catch { throw ApkExportError.localFileFailed }
        defer { reserved.destinationLease.release() }
        let writer = reserved.writer
        let sink: ApkExportArchiveWriter.Sink = { bytes in
            do { try await writer.write(bytes) } catch { throw ApkExportError.localFileFailed }
        }
        let archive = isSplit ? ApkExportArchiveWriter(sink: sink) : nil
        var completed: Int64 = 0
        var records: [ManifestFile] = []
        do {
            for component in manifest.components {
                try requireActive()
                let transfer = try await client.openDownload(sourcePath: manifest.path(component),
                    transferID: UUID().uuidString.lowercased(),
                    requestedOffsetBytes: 0)
                let opened = transfer.openResponse
                guard opened.acceptedOffsetBytes == 0, opened.totalSizeBytes == component.sizeBytes,
                      opened.hasAcceptedSourceFingerprint, opened.acceptedSourceFingerprint.sizeBytes == component.sizeBytes,
                      opened.acceptedSourceFingerprint.modifiedUnixMillis == 0,
                      opened.acceptedSourceFingerprint.providerEtag == manifest.etag(component) else {
                    throw ApkExportError.invalidResponse
                }
                try await archive?.begin(name: component.filename, size: component.sizeBytes)
                var hasher = SHA256()
                var received: Int64 = 0
                var final = false
                while !final {
                    try requireActive()
                    guard let chunk = try await transfer.nextChunk(), chunk.offsetBytes == received,
                          !chunk.data.isEmpty, Int64(chunk.data.count) <= component.sizeBytes - received,
                          Crc32.checksum(chunk.data) == chunk.crc32 else {
                        throw ApkExportError.invalidResponse
                    }
                    received += Int64(chunk.data.count)
                    guard chunk.finalChunk == (received == component.sizeBytes) else {
                        throw ApkExportError.invalidResponse
                    }
                    if let archive { try await archive.append(chunk.data) }
                    else { try await sink(chunk.data) }
                    hasher.update(data: chunk.data)
                    try requireActive()
                    try await transfer.acknowledge(chunk)
                    completed += Int64(chunk.data.count); final = chunk.finalChunk
                    await progress(.init(stage: .receiving, completedBytes: completed, totalBytes: manifest.totalBytes))
                }
                try await archive?.end()
                records.append(.init(file: component.filename, splitName: component.splitName,
                    sizeBytes: component.sizeBytes,
                    sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined()))
            }
            if let archive {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(ArchiveManifest(packageIdentifier: manifest.packageIdentifier,
                    versionCode: manifest.versionCode, updatedMillis: manifest.updatedMillis, components: records))
                try await archive.begin(name: "manifest.json", size: Int64(data.count))
                try await archive.append(data); try await archive.end(); try await archive.finish()
            }
            await progress(.init(stage: .validating, completedBytes: completed, totalBytes: manifest.totalBytes))
            try requireActive()
            try await client.validateApkExport(id: manifest.id)
            try requireActive()
            do { try await writer.commit() }
            catch {
                if error as? AtomicDownloadWriterError == .commitUncertain { throw ApkExportError.commitUncertain }
                throw ApkExportError.localFileFailed
            }
            try? await writer.close()
            return .init(filename: filename, componentCount: manifest.components.count, totalBytes: completed)
        } catch {
            if error as? ApkExportError != .commitUncertain { try? await writer.discardUnpublished() }
            try? await writer.close()
            throw error
        }
    }

    private func requireActive() throws {
        try Task.checkCancellation()
        guard active else { throw CancellationError() }
    }

    private struct ManifestFile: Encodable {
        let file: String
        let splitName: String
        let sizeBytes: Int64
        let sha256: String
    }
    private struct ArchiveManifest: Encodable {
        let format = "droidmatch-installed-apk-set"
        let formatVersion = 1
        let scope = "complete installed APK set for the source device; excludes application data"
        let packageIdentifier: String
        let versionCode: UInt64
        let updatedMillis: UInt64
        let components: [ManifestFile]
    }
}
