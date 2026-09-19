import Foundation

/// Streaming ZIP64, store method: APK signatures and compressed APK bytes remain
/// unchanged. Only fixed generated entry names are admitted; no peer-controlled path.
/// 中文：原样保存 APK；ZIP 是完整分包归档，不冒充 bundletool 的 .apks 格式。
actor ApkExportArchiveWriter {
    typealias Sink = @Sendable (Data) async throws -> Void
    private struct Entry {
        let name: String
        let offset: UInt64
        let size: UInt64
        var received: UInt64 = 0
        var crc = Crc32.Accumulator()
    }
    private let sink: Sink
    private var offset: UInt64 = 0
    private var current: Entry?
    private var entries: [Entry] = []
    private var finished = false

    init(sink: @escaping Sink) { self.sink = sink }

    func begin(name: String, size: Int64) async throws {
        guard !finished, current == nil, entries.count < 257, size >= 0,
              size <= ApkExportCodec.maximumComponentBytes,
              validName(name),
              name.utf8.count <= 32, !entries.contains(where: { $0.name == name }) else {
            throw ApkExportError.invalidResponse
        }
        current = Entry(name: name, offset: offset, size: UInt64(size))
        var data = Data()
        data.le32(0x04034b50); data.le16(45); data.le16(0x0808); data.le16(0)
        data.le16(0); data.le16(33); data.le32(0)
        data.le32(.max); data.le32(.max); data.le16(UInt16(name.utf8.count)); data.le16(20)
        data.append(contentsOf: name.utf8)
        data.le16(1); data.le16(16); data.le64(UInt64(size)); data.le64(UInt64(size))
        try await write(data)
    }

    func append(_ data: Data) async throws {
        guard var entry = current, UInt64(data.count) <= entry.size - entry.received else {
            throw ApkExportError.invalidResponse
        }
        entry.crc.update(data); entry.received += UInt64(data.count); current = entry
        try await write(data)
    }

    func end() async throws {
        guard let entry = current, entry.received == entry.size else { throw ApkExportError.invalidResponse }
        var descriptor = Data(); descriptor.le32(0x08074b50)
        descriptor.le32(entry.crc.checksum); descriptor.le64(entry.size); descriptor.le64(entry.size)
        try await write(descriptor)
        entries.append(entry); current = nil
    }

    func finish() async throws {
        guard !finished, current == nil, !entries.isEmpty,
              entries.contains(where: { $0.name == "base.apk" }),
              entries.contains(where: { $0.name == "manifest.json" }) else {
            throw ApkExportError.invalidResponse
        }
        finished = true
        let centralOffset = offset
        for entry in entries {
            var data = Data()
            data.le32(0x02014b50); data.le16(0x032d); data.le16(45); data.le16(0x0808)
            data.le16(0); data.le16(0); data.le16(33); data.le32(entry.crc.checksum)
            data.le32(.max); data.le32(.max); data.le16(UInt16(entry.name.utf8.count))
            data.le16(28); data.le16(0); data.le16(0); data.le16(0)
            data.le32(0o100600 << 16); data.le32(.max)
            data.append(contentsOf: entry.name.utf8)
            data.le16(1); data.le16(24); data.le64(entry.size); data.le64(entry.size); data.le64(entry.offset)
            try await write(data)
        }
        let centralSize = offset - centralOffset
        let endOffset = offset
        var data = Data()
        data.le32(0x06064b50); data.le64(44); data.le16(45); data.le16(45)
        data.le32(0); data.le32(0); data.le64(UInt64(entries.count)); data.le64(UInt64(entries.count))
        data.le64(centralSize); data.le64(centralOffset)
        data.le32(0x07064b50); data.le32(0); data.le64(endOffset); data.le32(1)
        data.le32(0x06054b50); data.le16(0); data.le16(0); data.le16(.max); data.le16(.max)
        data.le32(.max); data.le32(.max); data.le16(0)
        try await write(data)
    }

    private func write(_ data: Data) async throws { try await sink(data); offset += UInt64(data.count) }

    private func validName(_ name: String) -> Bool {
        if name == "base.apk" || name == "manifest.json" { return true }
        guard name.hasPrefix("split-"), name.hasSuffix(".apk"),
              let index = Int(name.dropFirst(6).dropLast(4)), (1...255).contains(index) else { return false }
        return name == "split-\(index).apk"
    }
}

private extension Data {
    mutating func le16(_ value: UInt16) { for shift in stride(from: 0, to: 16, by: 8) { append(UInt8(truncatingIfNeeded: value >> shift)) } }
    mutating func le32(_ value: UInt32) { for shift in stride(from: 0, to: 32, by: 8) { append(UInt8(truncatingIfNeeded: value >> shift)) } }
    mutating func le64(_ value: UInt64) { for shift in stride(from: 0, to: 64, by: 8) { append(UInt8(truncatingIfNeeded: value >> shift)) } }
}
