import Foundation
import Testing
@testable import DroidMatchCore

@Test func frameCodecRoundTripsOnePayload() throws {
    let codec = FrameCodec()
    let payload = Data("hello".utf8)

    var frame = try codec.encode(payload: payload)
    let decoded = try codec.decodeNext(from: &frame)

    #expect(decoded == payload)
    #expect(frame.isEmpty)
}

@Test func frameCodecWaitsForCompletePayload() throws {
    let codec = FrameCodec()
    let payload = Data("hello".utf8)
    let frame = try codec.encode(payload: payload)

    var partial = frame.prefix(6)
    let decoded = try codec.decodeNext(from: &partial)

    #expect(decoded == nil)
}

@Test func frameReaderDecodesMultiplePayloadsWithoutClearingBuffer() throws {
    let codec = FrameCodec()
    let reader = FrameReader(compactThreshold: 1024)
    let first = Data("first".utf8)
    let second = Data("second".utf8)

    var combined = Data()
    combined.append(try codec.encode(payload: first))
    combined.append(try codec.encode(payload: second))
    reader.append(combined)

    #expect(try reader.decodeNext() == first)
    #expect(try reader.decodeNext() == second)
    #expect(try reader.decodeNext() == nil)
}

@Test func frameReaderRequiresClearAfterInvalidFrame() throws {
    let codec = FrameCodec()
    let reader = FrameReader()
    reader.append(Data([0, 0, 0, 0]))

    #expect(throws: FrameCodecError.emptyFrame) {
        _ = try reader.decodeNext()
    }

    reader.append(try codec.encode(payload: Data("valid".utf8)))
    #expect(throws: FrameCodecError.emptyFrame) {
        _ = try reader.decodeNext()
    }

    reader.clear()
    reader.append(try codec.encode(payload: Data("valid".utf8)))
    #expect(try reader.decodeNext() == Data("valid".utf8))
}

@Test func frameCodecRejectsEmptyPayload() throws {
    let codec = FrameCodec()

    #expect(throws: FrameCodecError.emptyFrame) {
        _ = try codec.encode(payload: Data())
    }
}

@Test func crc32MatchesKnownVector() {
    let data = Data("123456789".utf8)
    #expect(Crc32.checksum(data) == 0xcbf43926)
}

@Test func adbDeviceParserHandlesLongOutput() {
    let output = """
    * daemon not running; starting now at tcp:5037
    * daemon started successfully
    List of devices attached
    ABC123 device product:oriole model:Pixel_6 device:oriole transport_id:1
    XYZ offline

    """

    let devices = AdbClient.parseDevices(output)

    #expect(devices.count == 2)
    #expect(devices[0].serial == "ABC123")
    #expect(devices[0].state == "device")
    #expect(devices[0].model == "Pixel_6")
    #expect(devices[1].state == "offline")
}

@Test func adbForwardParserHandlesEmptyAndMultipleForwards() {
    #expect(AdbClient.parseForwards("").isEmpty)

    let output = """
    ABC123 tcp:49152 tcp:39001
    XYZ tcp:49153 localabstract:droidmatch
    """

    let forwards = AdbClient.parseForwards(output)

    #expect(forwards.count == 2)
    #expect(forwards[0].serial == "ABC123")
    #expect(forwards[0].local == "tcp:49152")
    #expect(forwards[0].remote == "tcp:39001")
}
