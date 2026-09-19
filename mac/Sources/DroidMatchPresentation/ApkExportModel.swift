import Combine
import DroidMatchCore
import Foundation

@MainActor
public final class ApkExportModel: ObservableObject {
    @Published public private(set) var isBusy = false
    @Published public private(set) var isCancelling = false
    @Published public private(set) var progress: ApkExportProgress?
    @Published public private(set) var failure: ApkExportError?
    @Published public private(set) var selectedName: String?
    @Published public private(set) var completedFilename: String?
    @Published public private(set) var wasCancelled = false
    public var canExport: Bool { !closed && !views.isEmpty && !isBusy }

    private let client: any ApkExportClient
    private var views = Set<UUID>()
    private var closed = false
    private var generation: UInt64 = 0
    private var task: Task<Void, Never>?
    private var operationID: UUID?

    public init(client: any ApkExportClient) { self.client = client }
    deinit { task?.cancel() }
    public func attach(viewID: UUID) { if !closed { views.insert(viewID) } }
    public func detach(viewID: UUID) { views.remove(viewID); if views.isEmpty { clear() } }
    public func deactivate() { closed = true; views = []; clear() }

    /// App owns folder authorization until the client's final descriptor cleanup.
    /// A false return leaves the scope with the App. 中文：异步退出后才释放原生目录授权。
    @discardableResult
    public func export(entry: ApplicationLibraryEntry, to directoryURL: URL,
                       finished: @escaping @MainActor @Sendable () -> Void) -> Bool {
        guard canExport, directoryURL.isFileURL else { return false }
        let id = UUID(); let generation = self.generation; let client = self.client
        operationID = id; isBusy = true; isCancelling = false; wasCancelled = false
        failure = nil; completedFilename = nil; progress = nil
        selectedName = ProductDisplayText.value(entry.displayName)
        task = Task { [weak self] in
            defer { finished(); self?.settled(id) }
            do {
                let result = try await client.exportApk(packageIdentifier: entry.packageIdentifier,
                    directoryURL: directoryURL) { [weak self] progress in
                        await self?.accept(progress, generation: generation)
                    }
                guard let self, self.generation == generation else { return }
                // A successful atomic publication outranks a cancellation that
                // arrived after publication; never display it as an absent file.
                self.completedFilename = ProductDisplayText.value(result.filename, maximumScalars: 240)
            } catch {
                guard let self, self.generation == generation else { return }
                if error is CancellationError {
                    self.wasCancelled = true
                } else {
                    self.failure = error as? ApkExportError ?? .connectionUnavailable
                }
            }
        }
        return true
    }

    public func cancel() { if isBusy { isCancelling = true; task?.cancel() } }

    private func accept(_ value: ApkExportProgress, generation: UInt64) {
        guard self.generation == generation, isBusy, value.totalBytes >= 0,
              value.totalBytes <= 64 * 1024 * 1024 * 1024,
              (0...value.totalBytes).contains(value.completedBytes) else { return }
        progress = value
    }
    private func settled(_ id: UUID) {
        guard operationID == id else { return }
        operationID = nil; task = nil; isBusy = false; isCancelling = false; progress = nil; selectedName = nil
    }
    private func clear() {
        generation &+= 1
        task?.cancel()
        progress = nil; failure = nil; selectedName = nil; completedFilename = nil; wasCancelled = false
        // Keep admission closed until cancellation has really drained the client.
        // 中文：隐藏视图可以清空展示，不能在旧传输退出前重新接收任务。
        if isBusy { isCancelling = true }
    }
}
