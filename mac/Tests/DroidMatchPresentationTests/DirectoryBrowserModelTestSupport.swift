@testable import DroidMatchCore
@testable import DroidMatchPresentation
import Foundation
import Testing

// Shared test-target probe and fixtures preserve one ordering model across browser behavior suites.
// 中文：共享测试 target probe 与 fixture 让各浏览行为套件复用同一调用顺序模型。

actor DirectoryListingClientProbe: DirectoryBrowserClient {
    struct Call: Sendable, Equatable {
        let query: DirectoryListingQuery
        let pageToken: String?
    }

    private var calls: [Call] = []
    private var continuations: [Int: CheckedContinuation<DirectoryListingPage, any Error>] = [:]
    private var createdPaths: [String] = []
    private var createError: DirectoryMutationError?
    private var holdCreate = false
    private var createContinuation: CheckedContinuation<Void, any Error>?
    private var renamedPaths: [(String, String)] = []
    private var deletedPaths: [(String, Bool)] = []
    private var deleteFailureAt: Int?
    private var thumbnailRequests: [(String, UInt32)] = []
    private var holdThumbnails = false
    private var thumbnailContinuations: [String: CheckedContinuation<MediaThumbnail, any Error>] = [:]
    private var activeThumbnailCount = 0
    private var maximumActiveThumbnailCount = 0
    private let thumbnailCancellationCount = LockedValue(0)
    private var thumbnailData = Data([1, 2, 3])

    func createDirectory(path: String) async throws {
        createdPaths.append(path)
        if let createError { throw createError }
        if holdCreate {
            try await withCheckedThrowingContinuation { continuation in
                createContinuation = continuation
            }
        }
    }

    func setCreateError(_ error: DirectoryMutationError?) {
        createError = error
    }

    func lastCreatedPath() -> String? { createdPaths.last }

    func setCreateHold(_ hold: Bool) { holdCreate = hold }

    func completeCreate() {
        createContinuation?.resume(returning: ())
        createContinuation = nil
    }

    func renamePath(sourcePath: String, destinationPath: String) throws {
        renamedPaths.append((sourcePath, destinationPath))
        if let createError { throw createError }
    }

    func lastRename() -> [String]? {
        guard let value = renamedPaths.last else { return nil }
        return [value.0, value.1]
    }

    func deletePath(_ path: String, recursive: Bool) throws {
        deletedPaths.append((path, recursive))
        if deleteFailureAt == deletedPaths.count {
            throw DirectoryMutationError.remote(.unavailable)
        }
        if let createError { throw createError }
    }

    func lastDelete() -> (String, Bool)? { deletedPaths.last }

    func failDelete(at call: Int?) { deleteFailureAt = call }

    func deletes() -> [(String, Bool)] { deletedPaths }

    func thumbnail(path: String, maxDimensionPx: UInt32) async throws -> MediaThumbnail {
        thumbnailRequests.append((path, maxDimensionPx))
        let value = MediaThumbnail(
            encodedImage: thumbnailData,
            mimeType: "image/jpeg",
            widthPx: min(80, maxDimensionPx),
            heightPx: min(60, maxDimensionPx)
        )
        guard holdThumbnails else { return value }
        activeThumbnailCount += 1
        maximumActiveThumbnailCount = max(maximumActiveThumbnailCount, activeThumbnailCount)
        defer { activeThumbnailCount -= 1 }
        let cancellationCount = thumbnailCancellationCount
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                thumbnailContinuations[path] = continuation
            }
        } onCancel: {
            cancellationCount.update { $0 += 1 }
        }
    }

    func thumbnailCalls() -> [String] { thumbnailRequests.map(\.0) }
    func thumbnailCallCount() -> Int { thumbnailRequests.count }
    func thumbnailDimensions() -> [UInt32] { thumbnailRequests.map(\.1) }
    func setThumbnailHold(_ hold: Bool) { holdThumbnails = hold }
    func setThumbnailData(_ data: Data) { thumbnailData = data }
    func thumbnailActiveRequests() -> Int { activeThumbnailCount }
    func maximumThumbnailActiveRequests() -> Int { maximumActiveThumbnailCount }
    func thumbnailCancellations() -> Int { thumbnailCancellationCount.value() }

    func completeThumbnail(path: String) {
        thumbnailContinuations.removeValue(forKey: path)?.resume(returning: MediaThumbnail(
            encodedImage: thumbnailData,
            mimeType: "image/jpeg",
            widthPx: 80,
            heightPx: 60
        ))
    }

    func failThumbnail(path: String, error: MediaThumbnailError) {
        thumbnailContinuations.removeValue(forKey: path)?.resume(throwing: error)
    }

    func listDirectoryPage(
        query: DirectoryListingQuery,
        pageToken: String?
    ) async throws -> DirectoryListingPage {
        let number = calls.count + 1
        calls.append(Call(query: query, pageToken: pageToken))
        return try await withCheckedThrowingContinuation { continuation in
            continuations[number] = continuation
        }
    }

    func succeed(_ number: Int, _ page: DirectoryListingPage) {
        continuations.removeValue(forKey: number)?.resume(returning: page)
    }

    func fail(_ number: Int, _ error: DirectoryListingError) {
        continuations.removeValue(forKey: number)?.resume(throwing: error)
    }

    func cancel(_ number: Int) {
        continuations.removeValue(forKey: number)?.resume(
            throwing: CancellationError()
        )
    }

    func count() -> Int {
        calls.count
    }

    func call(_ number: Int) -> Call? {
        guard number > 0, number <= calls.count else { return nil }
        return calls[number - 1]
    }
}

func entry(_ path: String) -> DirectoryListingEntry {
    DirectoryListingEntry(
        path: path,
        name: String(path.split(separator: "/").last ?? "entry"),
        kind: .file,
        sizeBytes: 1,
        modifiedUnixMillis: 1,
        mimeType: "application/octet-stream",
        canRead: true,
        canWrite: false
    )
}

func page(
    _ entries: [DirectoryListingEntry],
    next: String? = nil
) -> DirectoryListingPage {
    DirectoryListingPage(entries: entries, nextPageToken: next)
}

func largeDirectoryPage(
    _ indexes: Range<Int>,
    next: String? = nil
) -> DirectoryListingPage {
    page(indexes.map { index in
        entry(String(format: "dm://app-sandbox/file-%04d.bin", index))
    }, next: next)
}

func waitForDirectoryCallCount(
    _ client: DirectoryListingClientProbe,
    _ expected: Int
) async -> Bool {
    for _ in 0..<200 {
        if await client.count() == expected { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return false
}

@MainActor
func waitForDirectoryPhase(
    _ model: DirectoryBrowserModel,
    _ expected: DirectoryBrowserPhase
) async -> Bool {
    for _ in 0..<200 {
        if model.phase == expected { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return false
}
