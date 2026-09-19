import Combine
import DroidMatchCore
import Foundation

/// Visible installation state belongs to one authenticated device session.
/// Android keeps the durable operation; this model stores no filenames or journal on disk.
@MainActor
public final class ApkInstallationModel: ObservableObject {
    @Published public private(set) var snapshot: ApkInstallationSnapshot?
    @Published public private(set) var failure: ApkInstallationError?
    @Published public private(set) var uploadFailure: ApkInstallationError?
    @Published public private(set) var uploadProgress: ApkInstallUploadProgress?
    @Published public private(set) var selectedFilename: String?
    @Published public private(set) var isUploading = false
    @Published public private(set) var isCancelling = false
    @Published public private(set) var isRefreshing = false

    public var canChooseFile: Bool {
        !closed && !views.isEmpty && !isUploading && !isCancelling
            && failure == nil && snapshot?.canStartInstall == true
    }

    private let client: any ApkInstallationClient
    private let pollInterval: Duration
    private var views = Set<UUID>()
    private var generation: UInt64 = 0
    private var closed = false
    private var pollTask: Task<Void, Never>?
    private var uploadTask: Task<Void, Never>?
    private var cancelTask: Task<Void, Never>?

    public init(client: any ApkInstallationClient, pollInterval: Duration = .seconds(2)) {
        self.client = client; self.pollInterval = pollInterval
    }
    deinit { pollTask?.cancel(); uploadTask?.cancel(); cancelTask?.cancel() }

    public func attach(viewID: UUID) {
        guard !closed else { return }
        let first = views.isEmpty
        views.insert(viewID)
        if first { refresh() }
    }

    public func detach(viewID: UUID) {
        views.remove(viewID)
        if views.isEmpty { clear() }
    }

    public func deactivate() {
        closed = true
        views = []
        clear()
    }

    public func refresh() {
        guard !closed, !views.isEmpty else { return }
        pollTask?.cancel()
        let generation = self.generation
        let client = self.client
        let interval = pollInterval
        isRefreshing = true
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let snapshot = try await client.installationSnapshot()
                    guard !Task.isCancelled, let self, self.generation == generation else { return }
                    self.snapshot = snapshot; self.failure = nil; self.isRefreshing = false
                } catch {
                    guard !Task.isCancelled, let self, self.generation == generation else { return }
                    self.snapshot = nil
                    self.failure = error as? ApkInstallationError ?? .connectionUnavailable
                    self.isRefreshing = false
                    if self.failure == .unsupported { return }
                }
                do { try await Task.sleep(for: interval) } catch { return }
            }
        }
    }

    /// The App keeps the native-panel scope alive through `finished`, including
    /// cancellation cleanup. Returning false transfers no ownership of that scope.
    /// 中文：文件授权持续到异步清理完成；拒绝接收时仍由 App 释放。
    @discardableResult
    public func upload(sourceURL: URL, finished: @escaping @MainActor @Sendable () -> Void) -> Bool {
        guard canChooseFile else { return false }
        guard sourceURL.isFileURL,
              let filename = ApkInstallationPolicy.acceptedFilename(sourceURL.lastPathComponent) else {
            uploadFailure = .invalidFile
            return false
        }
        let generation = self.generation
        let id = UUID().uuidString.lowercased()
        let client = self.client
        isUploading = true; uploadFailure = nil; selectedFilename = filename; uploadProgress = nil
        uploadTask = Task { [weak self] in
            defer { finished() }
            do {
                _ = try await client.uploadApk(sourceURL: sourceURL, operationID: id) { [weak self] progress in
                    await self?.accept(progress, generation: generation)
                }
                guard let self, self.generation == generation else { return }
                self.finishUpload(failure: Task.isCancelled ? .cancelled : nil)
            } catch {
                guard let self, self.generation == generation else { return }
                self.finishUpload(failure: Task.isCancelled || error is CancellationError
                    ? .cancelled : (error as? ApkInstallationError ?? .connectionUnavailable))
            }
        }
        return true
    }

    public func cancelUpload() { uploadTask?.cancel() }

    public func cancel(operation: ApkInstallationOperation) {
        guard !closed, !views.isEmpty, !isUploading, !isCancelling, operation.state.canCancel,
              snapshot?.operations.contains(operation) == true else { return }
        isCancelling = true; uploadFailure = nil
        let generation = self.generation
        let client = self.client
        cancelTask = Task { [weak self] in
            var failure: ApkInstallationError?
            do { _ = try await client.cancelInstallation(id: operation.id) }
            catch { failure = error as? ApkInstallationError ?? .connectionUnavailable }
            guard !Task.isCancelled, let self, self.generation == generation else { return }
            self.isCancelling = false; self.cancelTask = nil; self.uploadFailure = failure
            self.refresh()
        }
    }

    private func accept(_ progress: ApkInstallUploadProgress, generation: UInt64) {
        guard generation == self.generation, isUploading,
              progress.totalBytes > 0, progress.totalBytes <= ApkInstallationPolicy.maximumBytes,
              (0...progress.totalBytes).contains(progress.completedBytes) else { return }
        uploadProgress = progress
    }

    private func finishUpload(failure: ApkInstallationError?) {
        isUploading = false; uploadProgress = nil; selectedFilename = nil; uploadTask = nil
        uploadFailure = failure
        refresh()
    }

    private func clear() {
        generation &+= 1
        pollTask?.cancel(); pollTask = nil
        uploadTask?.cancel(); uploadTask = nil
        cancelTask?.cancel(); cancelTask = nil
        snapshot = nil; failure = nil; uploadFailure = nil; uploadProgress = nil; selectedFilename = nil
        isUploading = false; isCancelling = false; isRefreshing = false
    }
}
