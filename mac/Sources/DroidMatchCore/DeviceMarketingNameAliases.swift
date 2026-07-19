import Foundation

/// One reviewed, manufacturer-sourced name record. Localized names are product
/// identities, not translations produced by DroidMatch.
struct DeviceMarketingNameAliasRecord: Sendable {
    let model: String
    let device: String
    let product: String?
    let canonicalName: String
    let localizedNames: [String: String]
    let sourceURL: URL

    init(
        model: String,
        device: String,
        product: String? = nil,
        canonicalName: String,
        localizedNames: [String: String],
        sourceURL: URL
    ) {
        self.model = model
        self.device = device
        self.product = product
        self.canonicalName = canonicalName
        self.localizedNames = localizedNames
        self.sourceURL = sourceURL
    }
}

struct DeviceMarketingNameAliasCatalog: Sendable {
    static let maximumRecords = 128
    private let entries: [Entry]

    static let bundled = DeviceMarketingNameAliasCatalog(
        resourceData: DeviceMarketingNameAliasResource.bundledData()
    )

    init(records: [DeviceMarketingNameAliasRecord]) {
        entries = records.prefix(Self.maximumRecords).compactMap(Entry.init)
    }

    init(resourceData: Data?) {
        guard let resourceData,
              let records = DeviceMarketingNameAliasResource.records(from: resourceData),
              records.count <= Self.maximumRecords else {
            entries = []
            return
        }
        let validated = records.compactMap(Entry.init)
        entries = validated.count == records.count ? validated : []
    }

    func match(
        for query: DeviceCatalogQuery,
        preferredLanguageTags: [String]
    ) -> Match? {
        var bestSpecificity = 0
        var matchedEntry: Entry?
        var bestMatchIsAmbiguous = false
        for entry in entries {
            guard let specificity = entry.matchSpecificity(query) else { continue }
            if specificity > bestSpecificity {
                bestSpecificity = specificity
                matchedEntry = entry
                bestMatchIsAmbiguous = false
            } else if specificity == bestSpecificity {
                bestMatchIsAmbiguous = true
            }
        }
        guard let entry = matchedEntry, !bestMatchIsAmbiguous else { return nil }
        return Match(
            canonicalName: entry.canonicalName,
            displayName: entry.displayName(preferredLanguageTags: preferredLanguageTags)
        )
    }

    struct Match: Sendable {
        let canonicalName: String
        let displayName: String
    }

    private struct Entry: Sendable {
        let model: String
        let device: String
        let product: String?
        let canonicalName: String
        let localizedNames: [String: String]

        init?(_ record: DeviceMarketingNameAliasRecord) {
            guard let model = DeviceCatalogQuery.normalized(record.model),
                  let device = DeviceCatalogQuery.normalized(record.device),
                  let canonicalName = ProductDisplayText.value(record.canonicalName),
                  Self.validSource(record.sourceURL),
                  record.localizedNames.count <= 16 else { return nil }
            let product = DeviceCatalogQuery.normalized(record.product)
            if record.product != nil, product == nil { return nil }

            var localizedNames: [String: String] = [:]
            for (rawTag, rawName) in record.localizedNames {
                guard let tag = DeviceMarketingNameLocale.normalizedTag(rawTag),
                      let name = ProductDisplayText.value(rawName),
                      localizedNames[tag] == nil else { return nil }
                localizedNames[tag] = name
            }
            self.model = model
            self.device = device
            self.product = product
            self.canonicalName = canonicalName
            self.localizedNames = localizedNames
        }

        func matchSpecificity(_ query: DeviceCatalogQuery) -> Int? {
            guard query.model == model,
                  query.device == device else { return nil }
            if let product { return query.product == product ? 2 : nil }
            return 1
        }

        func displayName(preferredLanguageTags: [String]) -> String {
            for preferredTag in preferredLanguageTags {
                for candidate in DeviceMarketingNameLocale.fallbackTags(for: preferredTag) {
                    if let name = localizedNames[candidate] { return name }
                }
            }
            return canonicalName
        }

        private static func validSource(_ url: URL) -> Bool {
            guard url.absoluteString.utf8.count <= 2_048,
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  components.scheme?.lowercased() == "https",
                  components.host?.isEmpty == false,
                  components.user == nil,
                  components.password == nil,
                  components.fragment == nil else { return false }
            return true
        }
    }
}

enum DeviceMarketingNameLocale {
    private static let maximumPreferredLanguages = 16
    private static let maximumTagBytes = 64

    static func preferredTags(from values: [String]) -> [String] {
        var result: [String] = []
        for value in values.prefix(maximumPreferredLanguages) {
            guard let tag = normalizedTag(value), !result.contains(tag) else { continue }
            result.append(tag)
        }
        return result
    }

    static func normalizedTag(_ value: String) -> String? {
        let tag = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
        guard !tag.isEmpty, tag.utf8.count <= maximumTagBytes else { return nil }
        let components = tag.split(separator: "-", omittingEmptySubsequences: false)
        guard (1...8).contains(components.count),
              (2...3).contains(components[0].count),
              components[0].utf8.allSatisfy(Self.isASCIILetter) else { return nil }
        for component in components.dropFirst() {
            guard (2...8).contains(component.count),
                  component.utf8.allSatisfy({ Self.isASCIILetter($0) || Self.isASCIIDigit($0) })
            else { return nil }
        }
        return components.map { $0.lowercased() }.joined(separator: "-")
    }

    static func fallbackTags(for normalizedTag: String) -> [String] {
        let components = normalizedTag.split(separator: "-")
        guard let language = components.first else { return [] }
        var result = [normalizedTag]
        if let region = components.dropFirst().first(where: isRegion) {
            let regionalTag = "\(language)-\(region)"
            if !result.contains(regionalTag) { result.append(regionalTag) }
        }
        if let script = components.dropFirst().first(where: isScript) {
            let scriptTag = "\(language)-\(script)"
            if !result.contains(scriptTag) { result.append(scriptTag) }
        }
        let languageTag = String(language)
        if !result.contains(languageTag) { result.append(languageTag) }
        return result
    }

    private static func isScript(_ component: Substring) -> Bool {
        component.count == 4 && component.utf8.allSatisfy(isASCIILetter)
    }

    private static func isRegion(_ component: Substring) -> Bool {
        (component.count == 2 && component.utf8.allSatisfy(isASCIILetter))
            || (component.count == 3 && component.utf8.allSatisfy(isASCIIDigit))
    }

    private static func isASCIILetter(_ byte: UInt8) -> Bool {
        (65...90).contains(byte) || (97...122).contains(byte)
    }

    private static func isASCIIDigit(_ byte: UInt8) -> Bool {
        (48...57).contains(byte)
    }
}
