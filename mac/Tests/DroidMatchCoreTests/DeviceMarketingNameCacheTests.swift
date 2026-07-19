@testable import DroidMatchCore
import Foundation
import Testing

@Test func deviceMarketingNameResolverRevalidatesStaleCacheInBackground() async throws {
    let fixture = try ResolverFixture()
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let query = try #require(DeviceCatalogQuery(
        model: "MODEL-1",
        device: "device_code",
        product: "product_code"
    ))
    fixture.defaults.set([
        query.cacheKey: catalogCacheEntry(
            name: "Old Retail Phone",
            verifiedAt: now.addingTimeInterval(-61)
        ),
    ], forKey: "deviceMarketingNameCache.v3")
    let downloads = DeviceCatalogDownloadProbe(data: catalogFixture([
        ["Example", "Updated Retail Phone", "device_code", "MODEL-1"],
    ]))
    let resolver = DeviceMarketingNameResolver(
        defaults: fixture.defaults,
        minimumRefreshInterval: 60,
        clock: { now },
        downloader: { try await downloads.download() }
    )

    #expect(await resolver.marketingName(
        model: "MODEL-1",
        device: "device_code",
        product: "product_code"
    ) == "Old Retail Phone")
    #expect(await waitForMarketingName(resolver, expected: "Updated Retail Phone"))
    #expect(await downloads.count() == 1)
    let stored = try #require(
        storedCacheEntries(fixture.defaults)[query.cacheKey] as? [String: Any]
    )
    #expect(stored["name"] as? String == "Updated Retail Phone")
    #expect(stored["source"] as? String == "google-play-catalog-v1")
    #expect(stored["verifiedAt"] as? Double == now.timeIntervalSince1970)
}

@Test func deviceMarketingNameResolverKeepsFreshCacheFullyOffline() async throws {
    let fixture = try ResolverFixture()
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let query = try #require(DeviceCatalogQuery(
        model: "MODEL-1",
        device: "device_code",
        product: "product_code"
    ))
    fixture.defaults.set([
        query.cacheKey: catalogCacheEntry(
            name: "Fresh Retail Phone",
            verifiedAt: now.addingTimeInterval(-59)
        ),
    ], forKey: "deviceMarketingNameCache.v3")
    let downloads = DeviceCatalogDownloadProbe(error: TestCatalogError.offline)
    let resolver = DeviceMarketingNameResolver(
        defaults: fixture.defaults,
        minimumRefreshInterval: 60,
        clock: { now },
        downloader: { try await downloads.download() }
    )

    #expect(await resolver.marketingName(
        model: "MODEL-1",
        device: "device_code",
        product: "product_code"
    ) == "Fresh Retail Phone")
    #expect(await downloads.count() == 0)
}

@Test func deviceMarketingNameResolverDoesNotFreshenAnExpiredMemoryIndex() async throws {
    let fixture = try ResolverFixture()
    let clock = ResolverClock(Date(timeIntervalSince1970: 2_000_000_000))
    let downloads = DeviceCatalogSequenceDownloadProbe([
        catalogFixture([
            ["Example", "First Retail Phone", "first_device", "MODEL-FIRST"],
            ["Example", "Old Second Phone", "second_device", "MODEL-SECOND"],
        ]),
        catalogFixture([
            ["Example", "First Retail Phone", "first_device", "MODEL-FIRST"],
            ["Example", "Updated Second Phone", "second_device", "MODEL-SECOND"],
        ]),
    ])
    let resolver = DeviceMarketingNameResolver(
        defaults: fixture.defaults,
        minimumRefreshInterval: 60,
        clock: { clock.now() },
        downloader: { try await downloads.download() }
    )

    #expect(await resolver.marketingName(
        model: "MODEL-FIRST",
        device: "first_device",
        product: nil
    ) == nil)
    #expect(await waitForMarketingName(
        resolver,
        expected: "First Retail Phone",
        model: "MODEL-FIRST",
        device: "first_device",
        product: nil
    ))
    clock.advance(by: 61)
    #expect(await resolver.marketingName(
        model: "MODEL-SECOND",
        device: "second_device",
        product: nil
    ) == "Old Second Phone")
    #expect(await waitForMarketingName(
        resolver,
        expected: "Updated Second Phone",
        model: "MODEL-SECOND",
        device: "second_device",
        product: nil
    ))
    #expect(await downloads.count() == 2)
}

@Test func deviceMarketingNameResolverMigratesLegacyCacheAndRemovesMissingMatch() async throws {
    let fixture = try ResolverFixture()
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let query = try #require(DeviceCatalogQuery(
        model: "MODEL-REMOVED",
        device: "removed_device",
        product: nil
    ))
    fixture.defaults.set(
        [query.cacheKey: "Former Retail Phone"],
        forKey: "deviceMarketingNameCache.v2"
    )
    let downloads = DeviceCatalogDownloadProbe(data: catalogFixture([
        ["Example", "Catalog Sentinel", "sentinel_device", "SENTINEL"],
    ]))
    let resolver = DeviceMarketingNameResolver(
        defaults: fixture.defaults,
        minimumRefreshInterval: 60,
        clock: { now },
        downloader: { try await downloads.download() }
    )

    #expect(await resolver.marketingName(
        model: "MODEL-REMOVED",
        device: "removed_device",
        product: nil
    ) == nil)
    #expect(fixture.defaults.object(forKey: "deviceMarketingNameCache.v2") == nil)
    #expect(storedCacheEntries(fixture.defaults)[query.cacheKey] == nil)
    #expect(await waitForDownloadCount(downloads, expected: 1))
}

@Test func deviceMarketingNameResolverRejectsRemovedAliasAndMalformedV3Entries() async throws {
    let fixture = try ResolverFixture()
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let removedAliasQuery = try #require(DeviceCatalogQuery(
        model: "MODEL-ALIAS",
        device: "alias_device",
        product: nil
    ))
    let malformedQuery = try #require(DeviceCatalogQuery(
        model: "MODEL-MALFORMED",
        device: "malformed_device",
        product: nil
    ))
    fixture.defaults.set([
        removedAliasQuery.cacheKey: [
            "name": "Removed Reviewed Alias",
            "source": "reviewed-alias-v1",
        ],
        malformedQuery.cacheKey: [
            "name": "Poisoned Cache Name",
            "source": "google-play-catalog-v1",
            "verifiedAt": now.timeIntervalSince1970,
            "model": "RAW-MODEL-MUST-NOT-PERSIST",
        ],
    ], forKey: "deviceMarketingNameCache.v3")
    let downloads = DeviceCatalogHeldDownloadProbe(data: catalogFixture([
        ["Example", "Catalog Alias Replacement", "alias_device", "MODEL-ALIAS"],
        ["Example", "Catalog Valid Name", "malformed_device", "MODEL-MALFORMED"],
    ]))
    let resolver = DeviceMarketingNameResolver(
        defaults: fixture.defaults,
        minimumRefreshInterval: 60,
        clock: { now },
        aliasCatalog: DeviceMarketingNameAliasCatalog(records: []),
        downloader: { await downloads.download() }
    )

    let sanitizedCache = String(reflecting: storedCacheEntries(fixture.defaults))
    #expect(!sanitizedCache.contains("Poisoned Cache Name"))
    #expect(!sanitizedCache.contains("RAW-MODEL-MUST-NOT-PERSIST"))

    #expect(await resolver.marketingName(
        model: "MODEL-ALIAS",
        device: "alias_device",
        product: nil
    ) == nil)
    #expect(await resolver.marketingName(
        model: "MODEL-MALFORMED",
        device: "malformed_device",
        product: nil
    ) == nil)
    #expect(await waitForHeldDownload(downloads))
    await downloads.release()
    #expect(await waitForMarketingName(
        resolver,
        expected: "Catalog Alias Replacement",
        model: "MODEL-ALIAS",
        device: "alias_device",
        product: nil
    ))
    #expect(await resolver.marketingName(
        model: "MODEL-MALFORMED",
        device: "malformed_device",
        product: nil
    ) == "Catalog Valid Name")
    let stored = String(reflecting: storedCacheEntries(fixture.defaults))
    #expect(!stored.contains("Removed Reviewed Alias"))
    #expect(!stored.contains("Poisoned Cache Name"))
    #expect(!stored.contains("RAW-MODEL-MUST-NOT-PERSIST"))
}
