@testable import DroidMatchCore
import Foundation
import Testing

enum TestCatalogError: Error {
    case offline
}

final class ResolverFixture {
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

actor DeviceCatalogDownloadProbe {
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

actor DeviceCatalogSequenceDownloadProbe {
    private var responses: [Data]
    private var callCount = 0

    init(_ responses: [Data]) {
        self.responses = responses
    }

    func download() throws -> Data {
        callCount += 1
        guard !responses.isEmpty else { throw TestCatalogError.offline }
        return responses.removeFirst()
    }

    func count() -> Int { callCount }
}

final class ResolverClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        value = value.addingTimeInterval(interval)
        lock.unlock()
    }
}

actor DeviceCatalogHeldDownloadProbe {
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

func catalogFixture(_ rows: [[String]]) -> Data {
    let header = ["Retail Branding", "Marketing Name", "Device", "Model"]
    let text = ([header] + rows)
        .map { row in row.map(csvField).joined(separator: ",") }
        .joined(separator: "\n") + "\n"
    var data = Data([0xFF, 0xFE])
    data.append(text.data(using: .utf16LittleEndian)!)
    return data
}

func rowLimitCatalogFixture(emptyRowCount: Int) -> Data {
    var data = catalogFixture([
        ["Example", "Row Limit Sentinel", "device_limit", "MODEL-LIMIT"],
    ])
    let row = Data("\"\",\"\",\"\",\"\"\n".utf16LittleEndianBytes)
    data.reserveCapacity(data.count + (row.count * emptyRowCount))
    for _ in 0..<emptyRowCount { data.append(row) }
    return data
}

func bareCarriageReturnCatalogFixture() -> Data {
    let text = """
    "Retail Branding","Marketing Name","Device","Model"
    Example,Retail\rPhone,device_cr,MODEL-CR

    """
    var data = Data([0xFF, 0xFE])
    data.append(contentsOf: text.utf16LittleEndianBytes)
    return data
}

extension String {
    var utf16LittleEndianBytes: [UInt8] {
        utf16.flatMap { unit in
            [UInt8(truncatingIfNeeded: unit), UInt8(truncatingIfNeeded: unit >> 8)]
        }
    }
}

func csvField(_ value: String) -> String {
    "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
}

func waitForMarketingName(
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

func waitForNoMarketingName(
    _ resolver: DeviceMarketingNameResolver,
    model: String,
    device: String?,
    product: String?
) async -> Bool {
    for _ in 0..<100 {
        if await resolver.marketingName(
            model: model,
            device: device,
            product: product
        ) == nil { return true }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return false
}

func waitForDownloadCount(
    _ probe: DeviceCatalogDownloadProbe,
    expected: Int
) async -> Bool {
    for _ in 0..<100 {
        if await probe.count() == expected { return true }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return false
}

func waitForHeldDownload(_ probe: DeviceCatalogHeldDownloadProbe) async -> Bool {
    for _ in 0..<100 {
        if await probe.hasStarted() { return true }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return false
}

func waitForCacheCount(_ defaults: UserDefaults, expected: Int) async -> Bool {
    for _ in 0..<100 {
        if storedCacheEntries(defaults).count == expected { return true }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return false
}

func catalogCacheEntry(name: String, verifiedAt: Date) -> [String: Any] {
    [
        "name": name,
        "source": "google-play-catalog-v1",
        "verifiedAt": verifiedAt.timeIntervalSince1970,
    ]
}

func storedCacheEntries(_ defaults: UserDefaults) -> [String: Any] {
    defaults.dictionary(forKey: "deviceMarketingNameCache.v3") ?? [:]
}

func storedCacheNames(_ defaults: UserDefaults) -> [String] {
    storedCacheEntries(defaults).values.compactMap { value in
        (value as? [String: Any])?["name"] as? String
    }
}
