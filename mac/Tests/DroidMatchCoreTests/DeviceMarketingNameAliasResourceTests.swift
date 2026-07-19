@testable import DroidMatchCore
import Foundation
import Testing

@Test func deviceMarketingNameAliasResourceLoadsStrictVersionedData() throws {
    let catalog = DeviceMarketingNameAliasCatalog(resourceData: try aliasResourceData(records: [
        [
            "model": "MODEL-R",
            "device": "resource_device",
            "product": "carrier_variant",
            "canonicalName": "Original Name",
            "localizedNames": ["en": "English Name", "zh-Hans": "中文名称"],
            "sourceURL": "https://manufacturer.example/model-r",
        ],
    ]))
    let query = try #require(DeviceCatalogQuery(
        model: "MODEL-R",
        device: "resource_device",
        product: "carrier_variant"
    ))

    let match = try #require(catalog.match(
        for: query,
        preferredLanguageTags: ["zh-hans-cn"]
    ))
    #expect(match.canonicalName == "Original Name")
    #expect(match.displayName == "中文名称")
}

@Test func deviceMarketingNameAliasResourceRejectsUnknownShapeAndSchemaBoolean() throws {
    let unknownRoot = DeviceMarketingNameAliasCatalog(resourceData: try aliasResourceData(
        records: [],
        additions: ["unexpected": true]
    ))
    let booleanSchema = DeviceMarketingNameAliasCatalog(resourceData: try aliasResourceData(
        records: [],
        schemaVersion: true
    ))
    let floatingSchema = DeviceMarketingNameAliasCatalog(resourceData: try aliasResourceData(
        records: [],
        schemaVersion: 1.0
    ))
    let query = try #require(DeviceCatalogQuery(
        model: "MODEL-R",
        device: "resource_device",
        product: nil
    ))

    #expect(unknownRoot.match(for: query, preferredLanguageTags: []) == nil)
    #expect(booleanSchema.match(for: query, preferredLanguageTags: []) == nil)
    #expect(floatingSchema.match(for: query, preferredLanguageTags: []) == nil)
}

@Test func deviceMarketingNameAliasResourceRejectsWholeTableOnOneUnsafeRecord() throws {
    let records: [[String: Any]] = [
        [
            "model": "MODEL-GOOD",
            "device": "good_device",
            "canonicalName": "Good Name",
            "localizedNames": [:],
            "sourceURL": "https://manufacturer.example/good",
        ],
        [
            "model": "MODEL-BAD",
            "device": "bad_device",
            "canonicalName": "Bad Name",
            "localizedNames": [:],
            "sourceURL": "http://manufacturer.example/bad",
        ],
    ]
    let catalog = DeviceMarketingNameAliasCatalog(resourceData: try aliasResourceData(
        records: records
    ))
    let query = try #require(DeviceCatalogQuery(
        model: "MODEL-GOOD",
        device: "good_device",
        product: nil
    ))

    #expect(catalog.match(for: query, preferredLanguageTags: []) == nil)
}

@Test func deviceMarketingNameAliasResourceRejectsOversizedInput() throws {
    let data = Data(repeating: 0x20, count: DeviceMarketingNameAliasResource.maximumBytes + 1)
    let catalog = DeviceMarketingNameAliasCatalog(resourceData: data)
    let query = try #require(DeviceCatalogQuery(
        model: "MODEL-R",
        device: "resource_device",
        product: nil
    ))

    #expect(catalog.match(for: query, preferredLanguageTags: []) == nil)
}

@Test func assembledAppNeverFallsThroughToSwiftPMBuildResource() {
    var moduleFallbackWasRead = false

    let data = DeviceMarketingNameAliasResource.bundledData(
        mainResourceURL: nil,
        isAssembledApplication: true,
        moduleResourceData: {
            moduleFallbackWasRead = true
            return Data("outside signed app".utf8)
        }
    )

    #expect(data == nil)
    #expect(!moduleFallbackWasRead)
}

private func aliasResourceData(
    records: [[String: Any]],
    schemaVersion: Any = 1,
    additions: [String: Any] = [:]
) throws -> Data {
    var root: [String: Any] = [
        "schemaVersion": schemaVersion,
        "records": records,
    ]
    root.merge(additions) { _, new in new }
    return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
}
