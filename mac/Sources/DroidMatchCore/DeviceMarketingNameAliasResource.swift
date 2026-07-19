import Foundation

/// Loads the reviewed device-name data table. The assembled App installs this
/// file directly in its signed Resources directory; SwiftPM tests and harnesses
/// fall back to the target resource bundle.
enum DeviceMarketingNameAliasResource {
    static let fileName = "device-marketing-name-aliases"
    static let fileExtension = "json"
    static let maximumBytes = 128 * 1_024
    private static let schemaVersion = 1
    private static let rootKeys: Set<String> = ["schemaVersion", "records"]
    private static let requiredRecordKeys: Set<String> = [
        "model", "device", "canonicalName", "localizedNames", "sourceURL",
    ]
    private static let optionalRecordKeys: Set<String> = ["product"]

    static func bundledData() -> Data? {
        bundledData(
            mainResourceURL: Bundle.main.url(
                forResource: fileName,
                withExtension: fileExtension
            ),
            isAssembledApplication: Bundle.main.bundleURL.pathExtension
                .caseInsensitiveCompare("app") == .orderedSame,
            moduleResourceData: moduleBundledData
        )
    }

    static func bundledData(
        mainResourceURL: URL?,
        isAssembledApplication: Bool,
        moduleResourceData: () -> Data?
    ) -> Data? {
        if let mainResourceURL, let data = boundedData(at: mainResourceURL) {
            return data
        }
        // A packaged product must never fall through to SwiftPM's generated
        // absolute build-tree fallback. Missing or damaged signed data fails
        // closed; only tests and command-line products use Bundle.module.
        guard !isAssembledApplication else { return nil }
        return moduleResourceData()
    }

    private static func moduleBundledData() -> Data? {
        guard let moduleURL = Bundle.module.url(
            forResource: fileName,
            withExtension: fileExtension
        ) else { return nil }
        return boundedData(at: moduleURL)
    }

    static func records(from data: Data) -> [DeviceMarketingNameAliasRecord]? {
        guard !data.isEmpty, data.count <= maximumBytes,
              let value = try? JSONSerialization.jsonObject(with: data),
              let root = value as? [String: Any],
              Set(root.keys) == rootKeys,
              let version = root["schemaVersion"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(),
              !CFNumberIsFloatType(version),
              version.intValue == schemaVersion,
              version.doubleValue == Double(schemaVersion),
              let rawRecords = root["records"] as? [Any],
              rawRecords.count <= DeviceMarketingNameAliasCatalog.maximumRecords
        else { return nil }

        var records: [DeviceMarketingNameAliasRecord] = []
        records.reserveCapacity(rawRecords.count)
        for rawRecord in rawRecords {
            guard let record = record(from: rawRecord) else { return nil }
            records.append(record)
        }
        return records
    }

    private static func record(from value: Any) -> DeviceMarketingNameAliasRecord? {
        guard let object = value as? [String: Any],
              requiredRecordKeys.isSubset(of: object.keys),
              Set(object.keys).isSubset(of: requiredRecordKeys.union(optionalRecordKeys)),
              let model = object["model"] as? String,
              let device = object["device"] as? String,
              let canonicalName = object["canonicalName"] as? String,
              let rawLocalizedNames = object["localizedNames"] as? [String: Any],
              rawLocalizedNames.count <= 16,
              let source = object["sourceURL"] as? String,
              let sourceURL = URL(string: source) else { return nil }
        let product: String?
        if let rawProduct = object["product"] {
            guard let parsedProduct = rawProduct as? String else { return nil }
            product = parsedProduct
        } else {
            product = nil
        }
        var localizedNames: [String: String] = [:]
        for (tag, rawName) in rawLocalizedNames {
            guard let name = rawName as? String else { return nil }
            localizedNames[tag] = name
        }
        return DeviceMarketingNameAliasRecord(
            model: model,
            device: device,
            product: product,
            canonicalName: canonicalName,
            localizedNames: localizedNames,
            sourceURL: sourceURL
        )
    }

    private static func boundedData(at url: URL) -> Data? {
        guard url.isFileURL,
              let values = try? url.resourceValues(forKeys: [
                  .isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey,
              ]),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              let byteCount = values.fileSize,
              (1...maximumBytes).contains(byteCount),
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              data.count == byteCount else { return nil }
        return data
    }
}
