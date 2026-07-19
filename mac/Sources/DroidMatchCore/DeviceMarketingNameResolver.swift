import CryptoKit
import Foundation

private struct CachedName: Sendable {
    enum Source: String, Sendable {
        case googlePlayCatalog = "google-play-catalog-v1"
        case reviewedAlias = "reviewed-alias-v1"
        case legacyV2 = "legacy-v2"
    }

    private static let nameKey = "name"
    private static let sourceKey = "source"
    private static let verifiedAtKey = "verifiedAt"

    let name: String
    let source: Source
    let verifiedAt: Date?

    init(name: String, source: Source, verifiedAt: Date?) {
        self.name = name
        self.source = source
        self.verifiedAt = source == .googlePlayCatalog ? verifiedAt : nil
    }

    init?(propertyListValue value: [String: Any]) {
        guard let rawName = value[Self.nameKey] as? String,
              let name = ProductDisplayText.value(rawName),
              name == rawName,
              let rawSource = value[Self.sourceKey] as? String,
              let source = Source(rawValue: rawSource) else { return nil }
        let requiredKeys: Set<String>
        let verifiedAt: Date?
        if source == .googlePlayCatalog {
            requiredKeys = [Self.nameKey, Self.sourceKey, Self.verifiedAtKey]
            guard let seconds = value[Self.verifiedAtKey] as? Double,
                  seconds.isFinite,
                  seconds >= 0 else { return nil }
            verifiedAt = Date(timeIntervalSince1970: seconds)
        } else {
            requiredKeys = [Self.nameKey, Self.sourceKey]
            verifiedAt = nil
        }
        guard Set(value.keys) == requiredKeys else { return nil }
        self.name = name
        self.source = source
        self.verifiedAt = verifiedAt
    }

    var propertyListValue: [String: Any] {
        var value: [String: Any] = [
            Self.nameKey: name,
            Self.sourceKey: source.rawValue,
        ]
        if let verifiedAt {
            value[Self.verifiedAtKey] = verifiedAt.timeIntervalSince1970
        }
        return value
    }

    func isFresh(at now: Date, refreshInterval: TimeInterval) -> Bool {
        guard source == .googlePlayCatalog, let verifiedAt else { return false }
        let age = now.timeIntervalSince(verifiedAt)
        return age >= 0 && age < refreshInterval
    }
}

/// Resolves ADB model metadata to a UI-only retail name without sending a
/// per-device lookup request. A reviewed local catalog follows the Mac language
/// preference only when the manufacturer published that alias. Unknown devices
/// trigger one bounded full-catalog download; only hashed query keys and safe
/// canonical names are retained in local preferences.
actor DeviceMarketingNameResolver {
    typealias Downloader = @Sendable () async throws -> Data
    typealias Clock = @Sendable () -> Date

    static let catalogURL = URL(
        string: "https://storage.googleapis.com/play_public/supported_devices.csv"
    )!
    static let maximumCatalogBytes = 8 * 1_024 * 1_024
    static let refreshInterval: TimeInterval = 24 * 60 * 60
    static let maximumPendingQueries = 64

    private static let cacheDefaultsKey = "deviceMarketingNameCache.v3"
    private static let legacyCacheDefaultsKey = "deviceMarketingNameCache.v2"
    private static let maximumCachedNames = 512

    private let defaults: UserDefaults
    private let catalogLoader: DeviceCatalogLoader
    private let clock: Clock
    private let minimumRefreshInterval: TimeInterval
    private let aliasCatalog: DeviceMarketingNameAliasCatalog
    private let preferredLanguageTags: [String]
    private var cachedNames: [String: CachedName]
    private var pendingQueries = Set<DeviceCatalogQuery>()
    private var catalogIndex: DeviceCatalogIndex?
    private var catalogVerifiedAt: Date?
    private var refreshTask: Task<Void, Never>?
    private var nextRefreshDate = Date.distantPast

    init(
        defaults: UserDefaults = .standard,
        minimumRefreshInterval: TimeInterval = refreshInterval,
        clock: @escaping Clock = Date.init,
        preferredLanguages: [String] = Locale.preferredLanguages,
        aliasCatalog: DeviceMarketingNameAliasCatalog = .bundled,
        downloader: @escaping Downloader = DeviceMarketingNameResolver.downloadCatalog
    ) {
        self.defaults = defaults
        self.minimumRefreshInterval = max(60, minimumRefreshInterval)
        self.clock = clock
        self.aliasCatalog = aliasCatalog
        preferredLanguageTags = DeviceMarketingNameLocale.preferredTags(
            from: preferredLanguages
        )
        catalogLoader = DeviceCatalogLoader(downloader: downloader)
        let loadedCache = Self.loadCache(from: defaults)
        cachedNames = loadedCache.names
        if loadedCache.requiresRewrite {
            Self.persistCache(loadedCache.names, to: defaults)
        }
    }

    deinit {
        refreshTask?.cancel()
    }

    func marketingName(model: String?, device: String?, product: String?) -> String? {
        guard let query = DeviceCatalogQuery(
            model: model,
            device: device,
            product: product
        ) else { return nil }
        if let localMatch = aliasCatalog.match(
            for: query,
            preferredLanguageTags: preferredLanguageTags
        ) {
            let cached = cachedNames[query.cacheKey]
            if cached?.name != localMatch.canonicalName
                || cached?.source != .reviewedAlias {
                store(
                    localMatch.canonicalName,
                    source: .reviewedAlias,
                    verifiedAt: nil,
                    for: query
                )
            }
            return localMatch.displayName
        }
        if let cached = cachedNames[query.cacheKey] {
            if cached.source != .googlePlayCatalog {
                cachedNames.removeValue(forKey: query.cacheKey)
                persistCache()
            } else {
                if !cached.isFresh(
                    at: clock(),
                    refreshInterval: minimumRefreshInterval
                ) {
                    enqueueForRefresh(query)
                }
                return cached.name
            }
        }
        if let catalogIndex {
            let now = clock()
            let indexIsFresh = catalogVerifiedAt.map {
                isFresh(verifiedAt: $0, at: now)
            } ?? false
            let match = catalogIndex.marketingName(for: query)
            if let match, let catalogVerifiedAt {
                store(
                    match,
                    source: .googlePlayCatalog,
                    verifiedAt: catalogVerifiedAt,
                    for: query
                )
                if !indexIsFresh { enqueueForRefresh(query) }
                return match
            }
            if indexIsFresh { return nil }
        }

        enqueueForRefresh(query)
        return nil
    }

    private func enqueueForRefresh(_ query: DeviceCatalogQuery) {
        if pendingQueries.count < Self.maximumPendingQueries {
            pendingQueries.insert(query)
        }
        scheduleRefreshIfNeeded()
    }

    private func scheduleRefreshIfNeeded() {
        let now = clock()
        guard refreshTask == nil, now >= nextRefreshDate else { return }
        nextRefreshDate = now.addingTimeInterval(minimumRefreshInterval)
        let catalogLoader = self.catalogLoader
        refreshTask = Task(priority: .utility) { [weak self] in
            let index = await catalogLoader.loadIndex()
            await self?.finishRefresh(with: index)
        }
    }

    private func finishRefresh(with index: DeviceCatalogIndex?) {
        defer { refreshTask = nil }
        let queries = pendingQueries
        pendingQueries.removeAll()
        guard let index else { return }
        catalogIndex = index
        var cacheChanged = false
        let verifiedAt = clock()
        catalogVerifiedAt = verifiedAt
        for query in queries {
            if let name = index.marketingName(for: query) {
                store(
                    name,
                    source: .googlePlayCatalog,
                    verifiedAt: verifiedAt,
                    for: query,
                    persist: false
                )
                cacheChanged = true
            } else if cachedNames.removeValue(forKey: query.cacheKey) != nil {
                cacheChanged = true
            }
        }
        if cacheChanged { persistCache() }
    }

    private func store(
        _ name: String,
        source: CachedName.Source,
        verifiedAt: Date?,
        for query: DeviceCatalogQuery,
        persist: Bool = true
    ) {
        guard let safeName = ProductDisplayText.value(name) else { return }
        cachedNames[query.cacheKey] = CachedName(
            name: safeName,
            source: source,
            verifiedAt: verifiedAt
        )
        if cachedNames.count > Self.maximumCachedNames,
           let firstKey = cachedNames.keys
            .filter({ $0 != query.cacheKey })
            .sorted()
            .first {
            cachedNames.removeValue(forKey: firstKey)
        }
        if persist { persistCache() }
    }

    private func persistCache() {
        Self.persistCache(cachedNames, to: defaults)
    }

    private static func persistCache(
        _ names: [String: CachedName],
        to defaults: UserDefaults
    ) {
        defaults.set(
            names.mapValues(\.propertyListValue),
            forKey: cacheDefaultsKey
        )
        defaults.removeObject(forKey: legacyCacheDefaultsKey)
    }

    private static func loadCache(
        from defaults: UserDefaults
    ) -> (names: [String: CachedName], requiresRewrite: Bool) {
        if defaults.object(forKey: cacheDefaultsKey) != nil {
            guard let values = defaults.dictionary(forKey: cacheDefaultsKey) else {
                return ([:], true)
            }
            let names = loadCurrentCache(values)
            return (names, names.count != values.count)
        }
        guard let values = defaults.dictionary(forKey: legacyCacheDefaultsKey) else {
            return ([:], false)
        }
        var result: [String: CachedName] = [:]
        for key in values.keys.sorted() where result.count < maximumCachedNames {
            guard validCacheKey(key),
                  let rawName = values[key] as? String,
                  let safeName = ProductDisplayText.value(rawName) else { continue }
            result[key] = CachedName(
                name: safeName,
                source: .legacyV2,
                verifiedAt: nil
            )
        }
        return (result, true)
    }

    private static func loadCurrentCache(
        _ values: [String: Any]
    ) -> [String: CachedName] {
        var result: [String: CachedName] = [:]
        for key in values.keys.sorted() where result.count < maximumCachedNames {
            guard validCacheKey(key),
                  let value = values[key] as? [String: Any],
                  let cached = CachedName(propertyListValue: value) else { continue }
            result[key] = cached
        }
        return result
    }

    private static func validCacheKey(_ key: String) -> Bool {
        key.utf8.count == 64 && key.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    private func isFresh(verifiedAt: Date, at now: Date) -> Bool {
        let age = now.timeIntervalSince(verifiedAt)
        return age >= 0 && age < minimumRefreshInterval
    }

    private static func downloadCatalog() async throws -> Data {
        var request = URLRequest(url: catalogURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 15
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let redirectBlocker = DeviceCatalogRedirectBlocker()
        let (bytes, response) = try await session.bytes(
            for: request,
            delegate: redirectBlocker
        )
        guard let response = response as? HTTPURLResponse,
              response.statusCode == 200,
              response.url == catalogURL,
              response.expectedContentLength <= Int64(maximumCatalogBytes) else {
            throw DeviceCatalogError.invalidDownload
        }
        var buffer = DeviceCatalogDownloadBuffer(maximumBytes: maximumCatalogBytes)
        for try await byte in bytes {
            try buffer.append(byte)
        }
        return try buffer.value()
    }
}

/// Owns the synchronous CSV scan so catalog work never occupies the discovery
/// resolver actor. The executor boundary is explicit instead of relying on an
/// unstructured detached task for blocking work.
private actor DeviceCatalogLoader {
    private let downloader: DeviceMarketingNameResolver.Downloader

    init(downloader: @escaping DeviceMarketingNameResolver.Downloader) {
        self.downloader = downloader
    }

    func loadIndex() async -> DeviceCatalogIndex? {
        do {
            let data = try await downloader()
            return try GooglePlayDeviceCatalog.index(in: data)
        } catch {
            return nil
        }
    }
}

struct DeviceCatalogQuery: Hashable, Sendable {
    let model: String?
    let device: String?
    let product: String?
    let cacheKey: String

    init?(model: String?, device: String?, product: String?) {
        self.model = Self.normalized(model)
        self.device = Self.normalized(device)
        self.product = Self.normalized(product)
        guard self.model != nil || self.device != nil || self.product != nil else { return nil }
        let source = [self.model, self.device, self.product]
            .map { $0 ?? "" }
            .joined(separator: "\u{0000}")
        cacheKey = SHA256.hash(data: Data(source.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func normalized(_ value: String?) -> String? {
        DeviceCatalogText.identifier(value)
    }

    var matchingDevices: [String] {
        var values: [String] = []
        for value in [device, product] {
            if let value, !values.contains(value) {
                values.append(value)
            }
        }
        return values
    }
}

struct DeviceCatalogDownloadBuffer {
    private let maximumBytes: Int
    private var data = Data()

    init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
        data.reserveCapacity(max(0, maximumBytes))
    }

    mutating func append(_ byte: UInt8) throws {
        guard maximumBytes >= 0, data.count < maximumBytes else {
            throw DeviceCatalogError.invalidDownload
        }
        data.append(byte)
    }

    func value() throws -> Data {
        guard !data.isEmpty else { throw DeviceCatalogError.invalidDownload }
        return data
    }
}

private final class DeviceCatalogRedirectBlocker: NSObject,
    URLSessionTaskDelegate,
    @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

enum DeviceCatalogText {
    private static let maximumScalars = 512
    private static let locale = Locale(identifier: "en_US_POSIX")

    static func identifier(_ value: String?) -> String? {
        guard let normalized = normalized(value) else { return nil }
        let lowered = normalized.lowercased(with: locale)
            .precomposedStringWithCanonicalMapping
        guard lowered.unicodeScalars.count <= maximumScalars else { return nil }
        return lowered
    }

    static func marketingName(_ value: String?) -> String? {
        normalized(value)
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              normalized.unicodeScalars.count <= maximumScalars,
              normalized.unicodeScalars.allSatisfy({ scalar in
                switch scalar.properties.generalCategory {
                case .control, .format, .surrogate:
                    return false
                default:
                    return true
                }
              }) else { return nil }
        return normalized
    }
}

private enum DeviceCatalogError: Error {
    case invalidDownload
    case invalidEncoding
    case invalidCSV
}

private enum DeviceCatalogNameCandidate: Sendable {
    case unique(String)
    case ambiguous

    var uniqueName: String? {
        guard case let .unique(name) = self else { return nil }
        return name
    }

    mutating func add(_ name: String) {
        guard case let .unique(current) = self else { return }
        if current != name { self = .ambiguous }
    }

    mutating func merge(_ other: DeviceCatalogNameCandidate) {
        switch (self, other) {
        case let (.unique(current), .unique(candidate)) where current == candidate:
            break
        default:
            self = .ambiguous
        }
    }
}

private struct DeviceCatalogPair: Hashable, Sendable {
    let model: String
    let device: String
}

private struct DeviceCatalogIndex: Sendable {
    private var byPair: [DeviceCatalogPair: DeviceCatalogNameCandidate] = [:]
    private var byModel: [String: DeviceCatalogNameCandidate] = [:]
    private var byDevice: [String: DeviceCatalogNameCandidate] = [:]

    mutating func add(marketingName: String, model: String?, device: String?) {
        if let model {
            Self.add(marketingName, for: model, to: &byModel)
        }
        if let device {
            Self.add(marketingName, for: device, to: &byDevice)
        }
        if let model, let device {
            Self.add(
                marketingName,
                for: DeviceCatalogPair(model: model, device: device),
                to: &byPair
            )
        }
    }

    func marketingName(for query: DeviceCatalogQuery) -> String? {
        if let model = query.model {
            var pairCandidate: DeviceCatalogNameCandidate?
            for device in query.matchingDevices {
                Self.merge(byPair[DeviceCatalogPair(model: model, device: device)], into: &pairCandidate)
            }
            if let pairCandidate { return pairCandidate.uniqueName }
            if let modelCandidate = byModel[model] {
                return modelCandidate.uniqueName
            }
        }

        var deviceCandidate: DeviceCatalogNameCandidate?
        for device in query.matchingDevices {
            Self.merge(byDevice[device], into: &deviceCandidate)
        }
        return deviceCandidate?.uniqueName
    }

    private static func add<Key: Hashable>(
        _ name: String,
        for key: Key,
        to values: inout [Key: DeviceCatalogNameCandidate]
    ) {
        if var candidate = values[key] {
            candidate.add(name)
            values[key] = candidate
        } else {
            values[key] = .unique(name)
        }
    }

    private static func merge(
        _ candidate: DeviceCatalogNameCandidate?,
        into result: inout DeviceCatalogNameCandidate?
    ) {
        guard let candidate else { return }
        if var current = result {
            current.merge(candidate)
            result = current
        } else {
            result = candidate
        }
    }
}

enum GooglePlayDeviceCatalog {
    private static let expectedHeader = [
        "Retail Branding", "Marketing Name", "Device", "Model",
    ]
    private static let maximumRows = 200_000
    private static let maximumFieldScalars = 512

    static func validate(_ data: Data) throws {
        _ = try index(in: data)
    }

    fileprivate static func index(in data: Data) throws -> DeviceCatalogIndex {
        guard data.count >= 2,
              data.count <= DeviceMarketingNameResolver.maximumCatalogBytes,
              data[data.startIndex] == 0xFF,
              data[data.startIndex + 1] == 0xFE,
              let text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) else {
            throw DeviceCatalogError.invalidEncoding
        }
        var index = DeviceCatalogIndex()
        var rowNumber = 0
        try scanRows(in: text) { row in
            guard rowNumber < maximumRows else {
                throw DeviceCatalogError.invalidCSV
            }
            defer { rowNumber += 1 }
            if rowNumber == 0 {
                guard row == expectedHeader else { throw DeviceCatalogError.invalidCSV }
                return
            }
            guard row.count == 4,
                  let marketingName = DeviceCatalogText.marketingName(row[1]) else { return }
            let rowDevice = DeviceCatalogQuery.normalized(row[2])
            let rowModel = DeviceCatalogQuery.normalized(row[3])
            index.add(marketingName: marketingName, model: rowModel, device: rowDevice)
        }
        guard rowNumber > 1, rowNumber <= maximumRows else {
            throw DeviceCatalogError.invalidCSV
        }
        return index
    }

    private static func scanRows(
        in text: String,
        consume: ([String]) throws -> Void
    ) throws {
        var row: [String] = []
        var field = ""
        var fieldScalarCount = 0
        var quoted = false
        var closedQuote = false
        var index = text.startIndex

        func append(_ character: Character) throws {
            fieldScalarCount += character.unicodeScalars.count
            guard fieldScalarCount <= maximumFieldScalars else {
                throw DeviceCatalogError.invalidCSV
            }
            field.append(character)
        }

        func finishField() throws {
            guard row.count < expectedHeader.count else {
                throw DeviceCatalogError.invalidCSV
            }
            row.append(field)
            field = ""
            fieldScalarCount = 0
        }

        func finishRow() throws {
            try finishField()
            try consume(row)
            row.removeAll(keepingCapacity: true)
        }

        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if quoted {
                if character == "\"" {
                    if next < text.endIndex, text[next] == "\"" {
                        try append("\"")
                        index = text.index(after: next)
                        continue
                    }
                    quoted = false
                    closedQuote = true
                } else {
                    try append(character)
                }
            } else {
                if closedQuote {
                    switch character {
                    case ",":
                        try finishField()
                        closedQuote = false
                    case "\n":
                        try finishRow()
                        closedQuote = false
                    case "\r":
                        guard next < text.endIndex, text[next] == "\n" else {
                            throw DeviceCatalogError.invalidCSV
                        }
                    default:
                        throw DeviceCatalogError.invalidCSV
                    }
                    index = next
                    continue
                }
                switch character {
                case "\"":
                    guard field.isEmpty else { throw DeviceCatalogError.invalidCSV }
                    quoted = true
                case ",":
                    try finishField()
                case "\n":
                    try finishRow()
                case "\r":
                    guard next < text.endIndex, text[next] == "\n" else {
                        throw DeviceCatalogError.invalidCSV
                    }
                default:
                    try append(character)
                }
            }
            index = next
        }
        guard !quoted else { throw DeviceCatalogError.invalidCSV }
        if !field.isEmpty || !row.isEmpty {
            try finishRow()
        }
    }
}
