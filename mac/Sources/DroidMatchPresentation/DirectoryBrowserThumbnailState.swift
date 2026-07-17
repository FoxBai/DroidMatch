import Foundation

/// Pure thumbnail admission/cache state for one directory browser.
///
/// The MainActor model owns client Tasks and published UI values. This value
/// retains active requests across generation changes so draining old work still
/// counts against the live concurrency limit, while queued work, failures, and
/// optionally cached derivatives are invalidated atomically.
struct DirectoryBrowserThumbnailState {
    struct RequestKey: Hashable, Sendable {
        let generation: UInt64
        let path: String
    }

    private let maximumActiveRequests: Int
    private let maximumCachedCount: Int
    private let maximumCachedBytes: Int

    private(set) var generation: UInt64 = 0
    private(set) var images: [String: Data] = [:]
    private var activeKeys = Set<RequestKey>()
    private var queuedKeys = Set<RequestKey>()
    private var queue: [RequestKey] = []
    private var failedPaths = Set<String>()
    private var cacheOrder: [String] = []
    private var cachedBytes = 0

    init(
        maximumActiveRequests: Int = 4,
        maximumCachedCount: Int = 64,
        maximumCachedBytes: Int = 8 * 1_024 * 1_024
    ) {
        precondition(maximumActiveRequests > 0)
        precondition(maximumCachedCount > 0)
        precondition(maximumCachedBytes > 0)
        self.maximumActiveRequests = maximumActiveRequests
        self.maximumCachedCount = maximumCachedCount
        self.maximumCachedBytes = maximumCachedBytes
    }

    var activeRequestCount: Int {
        activeKeys.count
    }

    /// Invalidates queued/current-generation work but deliberately preserves
    /// active keys until their owning Tasks drain and call `finish`.
    mutating func invalidate(clearCache: Bool) {
        generation &+= 1
        queue.removeAll()
        queuedKeys.removeAll()
        failedPaths.removeAll()
        if clearCache {
            images.removeAll()
            cacheOrder.removeAll()
            cachedBytes = 0
        }
    }

    @discardableResult
    mutating func enqueue(path: String) -> Bool {
        guard images[path] == nil, !failedPaths.contains(path) else { return false }
        let key = RequestKey(generation: generation, path: path)
        guard !activeKeys.contains(key), !queuedKeys.contains(key) else { return false }
        queue.append(key)
        queuedKeys.insert(key)
        return true
    }

    mutating func nextRequest(visiblePaths: Set<String>) -> RequestKey? {
        guard activeKeys.count < maximumActiveRequests else { return nil }
        while !queue.isEmpty {
            let key = queue.removeFirst()
            queuedKeys.remove(key)
            guard key.generation == generation,
                  visiblePaths.contains(key.path),
                  images[key.path] == nil,
                  !failedPaths.contains(key.path) else {
                continue
            }
            activeKeys.insert(key)
            return key
        }
        return nil
    }

    mutating func finish(_ key: RequestKey) {
        activeKeys.remove(key)
    }

    func canPublish(_ key: RequestKey, visiblePaths: Set<String>) -> Bool {
        key.generation == generation && visiblePaths.contains(key.path)
    }

    @discardableResult
    mutating func store(_ image: Data, for key: RequestKey) -> Bool {
        guard key.generation == generation else { return false }
        if let replaced = images[key.path] {
            cachedBytes -= replaced.count
        }
        images[key.path] = image
        cachedBytes += image.count
        cacheOrder.removeAll { $0 == key.path }
        cacheOrder.append(key.path)
        evictIfNeeded()
        return true
    }

    @discardableResult
    mutating func recordFailure(for key: RequestKey) -> Bool {
        guard key.generation == generation else { return false }
        failedPaths.insert(key.path)
        return true
    }

    mutating func retainImages(for paths: Set<String>) {
        for path in images.keys.filter({ !paths.contains($0) }) {
            if let removed = images.removeValue(forKey: path) {
                cachedBytes -= removed.count
            }
        }
        cacheOrder.removeAll { !paths.contains($0) }
    }

    private mutating func evictIfNeeded() {
        while images.count > maximumCachedCount || cachedBytes > maximumCachedBytes {
            let evictedPath = cacheOrder.removeFirst()
            if let evicted = images.removeValue(forKey: evictedPath) {
                cachedBytes -= evicted.count
            }
        }
    }
}
