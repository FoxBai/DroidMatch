@testable import DroidMatchCore
import Foundation
import Testing

@Test func deviceMarketingNameResolverUsesBundled704SHRecordWithoutNetwork() async throws {
    let fixture = try ResolverFixture()
    var cachedNames = Dictionary(uniqueKeysWithValues: (0..<511).map { value in
        let suffix = String(format: "%08x", value)
        return (String(repeating: "0", count: 56) + suffix, "Cached Phone")
    })
    let old704Key = try #require(DeviceCatalogQuery(
        model: "704SH",
        device: "SG704SH",
        product: "S3"
    )).cacheKey
    cachedNames[old704Key] = "シンプルスマホ４"
    fixture.defaults.set(cachedNames, forKey: "deviceMarketingNameCache.v2")
    let downloads = DeviceCatalogDownloadProbe(data: Data())
    let resolver = DeviceMarketingNameResolver(
        defaults: fixture.defaults,
        preferredLanguages: ["zh-Hans-CN"],
        downloader: { try await downloads.download() }
    )

    let name = await resolver.marketingName(
        model: "704SH",
        device: "SG704SH",
        product: "S3"
    )

    #expect(name == "シンプルスマホ4")
    #expect(await downloads.count() == 0)
    let stored = fixture.defaults.dictionary(forKey: "deviceMarketingNameCache.v2") ?? [:]
    #expect(stored.count == 512)
    #expect(stored.values.contains { ($0 as? String) == "シンプルスマホ4" })
    #expect(!stored.values.contains { ($0 as? String) == "シンプルスマホ４" })
    #expect(await resolver.marketingName(
        model: String(repeating: "X", count: 513),
        device: nil,
        product: nil
    ) == nil)
    #expect(await downloads.count() == 0)
}

@Test func deviceMarketingNameResolverDownloadsWholeCatalogThenCachesHashedLookup() async throws {
    let fixture = try ResolverFixture()
    let downloads = DeviceCatalogDownloadProbe(data: catalogFixture([
        ["Sharp", "シンプルスマホ4", "SG704SH", "704SH"],
        ["Example", "Retail Phone", "device_code", "MODEL-1"],
        ["Example", "Second, \"Quoted\" Phone", "second_device", "MODEL-2"],
    ]))
    let resolver = DeviceMarketingNameResolver(
        defaults: fixture.defaults,
        downloader: { try await downloads.download() }
    )

    #expect(await resolver.marketingName(
        model: "MODEL-1",
        device: "device_code",
        product: "product_code"
    ) == nil)
    #expect(await waitForMarketingName(resolver, expected: "Retail Phone"))
    #expect(await downloads.count() == 1)
    #expect(await resolver.marketingName(
        model: "MODEL-2",
        device: "second_device",
        product: nil
    ) == "Second, \"Quoted\" Phone")
    #expect(await downloads.count() == 1)

    let stored = fixture.defaults.dictionary(forKey: "deviceMarketingNameCache.v2") ?? [:]
    #expect(stored.values.contains { ($0 as? String) == "Retail Phone" })
    #expect(!String(reflecting: stored).contains("MODEL-1"))
    #expect(!String(reflecting: stored).contains("device_code"))

    let offline = DeviceCatalogDownloadProbe(error: TestCatalogError.offline)
    let restoredResolver = DeviceMarketingNameResolver(
        defaults: fixture.defaults,
        downloader: { try await offline.download() }
    )
    #expect(await restoredResolver.marketingName(
        model: "MODEL-1",
        device: "device_code",
        product: "product_code"
    ) == "Retail Phone")
    #expect(await offline.count() == 0)
}

@Test func deviceMarketingNameResolverSelectsReviewedAliasesByPreferredLanguage() async throws {
    let fixture = try ResolverFixture()
    let downloads = DeviceCatalogDownloadProbe(data: Data())
    let aliases = DeviceMarketingNameAliasCatalog(records: [
        DeviceMarketingNameAliasRecord(
            model: "MODEL-L",
            device: "locale_device",
            canonicalName: "Example Original",
            localizedNames: [
                "zh-Hans": "示例手机",
                "zh-Hant": "範例手機",
                "zh-HK": "香港示例手機",
                "en": "Example Phone",
            ],
            sourceURL: URL(string: "https://manufacturer.example/devices/model-l")!
        ),
        DeviceMarketingNameAliasRecord(
            model: "MODEL-L",
            device: "locale_device",
            product: "carrier_product",
            canonicalName: "Carrier Original",
            localizedNames: ["en": "Carrier Phone"],
            sourceURL: URL(string: "https://manufacturer.example/devices/model-l-carrier")!
        ),
    ])

    for (languages, expected) in [
        (["zh-Hans-CN"], "示例手机"),
        (["zh-Hant-HK"], "香港示例手機"),
        (["zh-Hant-TW"], "範例手機"),
        (["fr-FR", "en-GB"], "Example Phone"),
        (["de-DE"], "Example Original"),
    ] {
        let resolver = DeviceMarketingNameResolver(
            defaults: fixture.defaults,
            preferredLanguages: languages,
            aliasCatalog: aliases,
            downloader: { try await downloads.download() }
        )
        #expect(await resolver.marketingName(
            model: "MODEL-L",
            device: "locale_device",
            product: nil
        ) == expected)
    }

    #expect(await downloads.count() == 0)
    let productResolver = DeviceMarketingNameResolver(
        defaults: fixture.defaults,
        preferredLanguages: ["en-US"],
        aliasCatalog: aliases,
        downloader: { try await downloads.download() }
    )
    #expect(await productResolver.marketingName(
        model: "MODEL-L",
        device: "locale_device",
        product: "carrier_product"
    ) == "Carrier Phone")
    #expect(await downloads.count() == 0)
    let stored = fixture.defaults.dictionary(forKey: "deviceMarketingNameCache.v2") ?? [:]
    #expect(stored.values.contains { ($0 as? String) == "Example Original" })
    #expect(!stored.values.contains { ($0 as? String) == "示例手机" })
}

@Test func deviceMarketingNameResolverFailsClosedOnUnreviewableAliasRecords() async throws {
    let fixture = try ResolverFixture()
    let downloads = DeviceCatalogDownloadProbe(data: catalogFixture([
        ["Example", "Catalog Duplicate", "duplicate_device", "MODEL-DUP"],
        ["Example", "Catalog Unsafe", "unsafe_device", "MODEL-UNSAFE"],
        ["Example", "Catalog Variant", "other_variant", "MODEL-L"],
        ["Example", "Catalog Locale Duplicate", "locale_dup", "MODEL-LOCALE-DUP"],
        ["Example", "Catalog Bad Locale", "locale_bad", "MODEL-LOCALE-BAD"],
        ["Example", "Catalog User Info", "userinfo_device", "MODEL-USERINFO"],
        ["Example", "Catalog Fragment", "fragment_device", "MODEL-FRAGMENT"],
        ["Example", "Catalog Alias Limit", "alias_limit", "MODEL-ALIASES"],
        ["Example", "Catalog Record Limit", "record_limit", "MODEL-RECORD-LIMIT"],
    ]))
    var records = [
        DeviceMarketingNameAliasRecord(
            model: "MODEL-DUP",
            device: "duplicate_device",
            canonicalName: "First Local Name",
            localizedNames: ["en": "First Local Name"],
            sourceURL: URL(string: "https://manufacturer.example/model-dup")!
        ),
        DeviceMarketingNameAliasRecord(
            model: "MODEL-DUP",
            device: "duplicate_device",
            canonicalName: "Second Local Name",
            localizedNames: ["en": "Second Local Name"],
            sourceURL: URL(string: "https://manufacturer.example/model-dup-2")!
        ),
        DeviceMarketingNameAliasRecord(
            model: "MODEL-UNSAFE",
            device: "unsafe_device",
            canonicalName: "Unsafe Local Name",
            localizedNames: ["en": "Unsafe Local Name"],
            sourceURL: URL(string: "http://manufacturer.example/model-unsafe")!
        ),
        DeviceMarketingNameAliasRecord(
            model: "MODEL-L",
            device: "locale_device",
            canonicalName: "Local Variant Name",
            localizedNames: ["en": "Local Variant Name"],
            sourceURL: URL(string: "https://manufacturer.example/model-l")!
        ),
        DeviceMarketingNameAliasRecord(
            model: "MODEL-LOCALE-DUP",
            device: "locale_dup",
            canonicalName: "Local Locale Duplicate",
            localizedNames: ["en-US": "First", "en_us": "Second"],
            sourceURL: URL(string: "https://manufacturer.example/locale-dup")!
        ),
        DeviceMarketingNameAliasRecord(
            model: "MODEL-LOCALE-BAD",
            device: "locale_bad",
            canonicalName: "Local Bad Locale",
            localizedNames: ["en--US": "Bad Locale"],
            sourceURL: URL(string: "https://manufacturer.example/locale-bad")!
        ),
        DeviceMarketingNameAliasRecord(
            model: "MODEL-USERINFO",
            device: "userinfo_device",
            canonicalName: "Local User Info",
            localizedNames: ["en": "Local User Info"],
            sourceURL: URL(string: "https://user@manufacturer.example/userinfo")!
        ),
        DeviceMarketingNameAliasRecord(
            model: "MODEL-FRAGMENT",
            device: "fragment_device",
            canonicalName: "Local Fragment",
            localizedNames: ["en": "Local Fragment"],
            sourceURL: URL(string: "https://manufacturer.example/fragment#unsafe")!
        ),
        DeviceMarketingNameAliasRecord(
            model: "MODEL-ALIASES",
            device: "alias_limit",
            canonicalName: "Local Alias Limit",
            localizedNames: Dictionary(uniqueKeysWithValues: (0..<17).map {
                (String(format: "en-%02d", $0), "Alias \($0)")
            }),
            sourceURL: URL(string: "https://manufacturer.example/alias-limit")!
        ),
    ]
    for value in 0..<(128 - records.count) {
        records.append(DeviceMarketingNameAliasRecord(
            model: "FILLER-\(value)",
            device: "filler_\(value)",
            canonicalName: "Filler \(value)",
            localizedNames: ["en": "Filler \(value)"],
            sourceURL: URL(string: "https://manufacturer.example/filler/\(value)")!
        ))
    }
    records.append(DeviceMarketingNameAliasRecord(
        model: "MODEL-RECORD-LIMIT",
        device: "record_limit",
        canonicalName: "Local Record Limit",
        localizedNames: ["en": "Local Record Limit"],
        sourceURL: URL(string: "https://manufacturer.example/record-limit")!
    ))
    let aliases = DeviceMarketingNameAliasCatalog(records: records)
    let resolver = DeviceMarketingNameResolver(
        defaults: fixture.defaults,
        preferredLanguages: ["en-US"],
        aliasCatalog: aliases,
        downloader: { try await downloads.download() }
    )

    #expect(await resolver.marketingName(
        model: "MODEL-DUP",
        device: "duplicate_device",
        product: nil
    ) == nil)
    #expect(await waitForMarketingName(
        resolver,
        expected: "Catalog Duplicate",
        model: "MODEL-DUP",
        device: "duplicate_device",
        product: nil
    ))
    let fallbackCases: [(String, String, String?, String)] = [
        ("MODEL-UNSAFE", "unsafe_device", nil, "Catalog Unsafe"),
        ("MODEL-L", "other_variant", "locale_device", "Catalog Variant"),
        ("MODEL-LOCALE-DUP", "locale_dup", nil, "Catalog Locale Duplicate"),
        ("MODEL-LOCALE-BAD", "locale_bad", nil, "Catalog Bad Locale"),
        ("MODEL-USERINFO", "userinfo_device", nil, "Catalog User Info"),
        ("MODEL-FRAGMENT", "fragment_device", nil, "Catalog Fragment"),
        ("MODEL-ALIASES", "alias_limit", nil, "Catalog Alias Limit"),
        ("MODEL-RECORD-LIMIT", "record_limit", nil, "Catalog Record Limit"),
    ]
    for (model, device, product, expected) in fallbackCases {
        #expect(await resolver.marketingName(
            model: model,
            device: device,
            product: product
        ) == expected)
    }
    #expect(await downloads.count() == 1)
}

@Test func deviceMarketingNameResolverRequiresUnambiguousBestCatalogMatch() async throws {
    let fixture = try ResolverFixture()
    let longIdentityPrefix = String(repeating: "A", count: 120)
    let longNamePrefix = String(repeating: "Phone", count: 30)
    let downloads = DeviceCatalogDownloadProbe(data: catalogFixture([
        ["Example", "Sentinel Phone", "sentinel_device", "SENTINEL"],
        ["Wrong", "Wrong Match", "wrong_device", longIdentityPrefix + "Y"],
        ["First", longNamePrefix + "X", "first_device", "AMBIGUOUS"],
        ["Second", longNamePrefix + "Y", "second_device", "AMBIGUOUS"],
    ]))
    let resolver = DeviceMarketingNameResolver(
        defaults: fixture.defaults,
        minimumRefreshInterval: 60,
        downloader: { try await downloads.download() }
    )

    #expect(await resolver.marketingName(
        model: "SENTINEL",
        device: "sentinel_device",
        product: nil
    ) == nil)
    #expect(await waitForMarketingName(
        resolver,
        expected: "Sentinel Phone",
        model: "SENTINEL",
        device: "sentinel_device",
        product: nil
    ))
    #expect(await resolver.marketingName(
        model: longIdentityPrefix + "X",
        device: nil,
        product: nil
    ) == nil)
    #expect(await resolver.marketingName(
        model: "AMBIGUOUS",
        device: nil,
        product: nil
    ) == nil)
    #expect(await downloads.count() == 1)
}

@Test func deviceMarketingNameResolverRejectsMalformedOrOversizedCatalogs() async throws {
    var buffer = DeviceCatalogDownloadBuffer(maximumBytes: 2)
    try buffer.append(1)
    try buffer.append(2)
    do {
        try buffer.append(3)
        Issue.record("bounded catalog buffer accepted a byte beyond its limit")
    } catch {}
    #expect(try buffer.value() == Data([1, 2]))

    let boundedFixture = try ResolverFixture()
    let heldDownload = DeviceCatalogHeldDownloadProbe(data: catalogFixture(
        (0..<100).map { value in
            ["Example", "Phone \(value)", "device_\(value)", "MODEL-\(value)"]
        }
    ))
    let boundedResolver = DeviceMarketingNameResolver(
        defaults: boundedFixture.defaults,
        downloader: { await heldDownload.download() }
    )
    for value in 0..<100 {
        #expect(await boundedResolver.marketingName(
            model: "MODEL-\(value)",
            device: "device_\(value)",
            product: nil
        ) == nil)
    }
    #expect(await waitForHeldDownload(heldDownload))
    await heldDownload.release()
    #expect(await waitForCacheCount(
        boundedFixture.defaults,
        expected: DeviceMarketingNameResolver.maximumPendingQueries
    ))

    let atRowLimit = rowLimitCatalogFixture(emptyRowCount: 199_998)
    let overRowLimit = rowLimitCatalogFixture(emptyRowCount: 199_999)
    #expect(atRowLimit.count < DeviceMarketingNameResolver.maximumCatalogBytes)
    #expect(overRowLimit.count < DeviceMarketingNameResolver.maximumCatalogBytes)
    try GooglePlayDeviceCatalog.validate(atRowLimit)
    do {
        try GooglePlayDeviceCatalog.validate(overRowLimit)
        Issue.record("catalog parser accepted a row beyond its limit")
    } catch {}
    for data in [
        Data("not utf16 csv".utf8),
        Data(repeating: 0, count: DeviceMarketingNameResolver.maximumCatalogBytes + 1),
    ] {
        let fixture = try ResolverFixture()
        let downloads = DeviceCatalogDownloadProbe(data: data)
        let resolver = DeviceMarketingNameResolver(
            defaults: fixture.defaults,
            downloader: { try await downloads.download() }
        )
        #expect(await resolver.marketingName(
            model: "UNKNOWN",
            device: "unknown_device",
            product: nil
        ) == nil)
        #expect(await waitForDownloadCount(downloads, expected: 1))
        #expect(await resolver.marketingName(
            model: "UNKNOWN",
            device: "unknown_device",
            product: nil
        ) == nil)
        #expect(await downloads.count() == 1)
    }

    let bareCarriageReturnFixture = try ResolverFixture()
    let bareCarriageReturnDownloads = DeviceCatalogDownloadProbe(
        data: bareCarriageReturnCatalogFixture()
    )
    let bareCarriageReturnResolver = DeviceMarketingNameResolver(
        defaults: bareCarriageReturnFixture.defaults,
        downloader: { try await bareCarriageReturnDownloads.download() }
    )
    #expect(await bareCarriageReturnResolver.marketingName(
        model: "MODEL-CR",
        device: "device_cr",
        product: nil
    ) == nil)
    #expect(!(await waitForMarketingName(
        bareCarriageReturnResolver,
        expected: "RetailPhone",
        model: "MODEL-CR",
        device: "device_cr",
        product: nil
    )))
}

private enum TestCatalogError: Error {
    case offline
}

private final class ResolverFixture {
    let suiteName = "DeviceMarketingNameResolverTests.\(UUID().uuidString)"
    // UserDefaults is documented as thread-safe, but Foundation does not mark
    // it Sendable. Tests intentionally share one isolated suite to prove that a
    // second resolver can read the first resolver's persisted cache.
    nonisolated(unsafe) let defaults: UserDefaults

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

private actor DeviceCatalogDownloadProbe {
    private let result: Result<Data, any Error>
    private var callCount = 0

    init(data: Data) {
        result = .success(data)
    }

    init(error: any Error) {
        result = .failure(error)
    }

    func download() throws -> Data {
        callCount += 1
        return try result.get()
    }

    func count() -> Int { callCount }
}

private actor DeviceCatalogHeldDownloadProbe {
    private let data: Data
    private var continuation: CheckedContinuation<Data, Never>?
    private var started = false

    init(data: Data) {
        self.data = data
    }

    func download() async -> Data {
        started = true
        return await withCheckedContinuation { continuation = $0 }
    }

    func hasStarted() -> Bool { started }

    func release() {
        continuation?.resume(returning: data)
        continuation = nil
    }
}

private func catalogFixture(_ rows: [[String]]) -> Data {
    let header = ["Retail Branding", "Marketing Name", "Device", "Model"]
    let text = ([header] + rows)
        .map { row in row.map(csvField).joined(separator: ",") }
        .joined(separator: "\n") + "\n"
    var data = Data([0xFF, 0xFE])
    data.append(text.data(using: .utf16LittleEndian)!)
    return data
}

private func rowLimitCatalogFixture(emptyRowCount: Int) -> Data {
    var data = catalogFixture([
        ["Example", "Row Limit Sentinel", "device_limit", "MODEL-LIMIT"],
    ])
    let row = Data("\"\",\"\",\"\",\"\"\n".utf16LittleEndianBytes)
    data.reserveCapacity(data.count + (row.count * emptyRowCount))
    for _ in 0..<emptyRowCount { data.append(row) }
    return data
}

private func bareCarriageReturnCatalogFixture() -> Data {
    let text = """
    "Retail Branding","Marketing Name","Device","Model"
    Example,Retail\rPhone,device_cr,MODEL-CR

    """
    var data = Data([0xFF, 0xFE])
    data.append(contentsOf: text.utf16LittleEndianBytes)
    return data
}

private extension String {
    var utf16LittleEndianBytes: [UInt8] {
        utf16.flatMap { unit in
            [UInt8(truncatingIfNeeded: unit), UInt8(truncatingIfNeeded: unit >> 8)]
        }
    }
}

private func csvField(_ value: String) -> String {
    "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
}

private func waitForMarketingName(
    _ resolver: DeviceMarketingNameResolver,
    expected: String,
    model: String = "MODEL-1",
    device: String? = "device_code",
    product: String? = "product_code"
) async -> Bool {
    for _ in 0..<100 {
        if await resolver.marketingName(
            model: model,
            device: device,
            product: product
        ) == expected { return true }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return false
}

private func waitForDownloadCount(
    _ probe: DeviceCatalogDownloadProbe,
    expected: Int
) async -> Bool {
    for _ in 0..<100 {
        if await probe.count() == expected { return true }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return false
}

private func waitForHeldDownload(_ probe: DeviceCatalogHeldDownloadProbe) async -> Bool {
    for _ in 0..<100 {
        if await probe.hasStarted() { return true }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return false
}

private func waitForCacheCount(_ defaults: UserDefaults, expected: Int) async -> Bool {
    for _ in 0..<100 {
        if defaults.dictionary(forKey: "deviceMarketingNameCache.v2")?.count == expected {
            return true
        }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return false
}
