import Foundation
import Network
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

@Test func clientHelloEnvelopeBinaryRoundTrips() throws {
    var hello = Droidmatch_V1_ClientHello()
    hello.clientName = "DroidMatchHarness"
    hello.clientVersion = "0.1.0-m1"
    hello.protocolMajor = 1
    hello.protocolMinor = 0
    hello.transport = .adb
    hello.requestedCapabilities = [.diagnostics]

    var envelope = Droidmatch_V1_RpcEnvelope()
    envelope.frameVersion = 1
    envelope.kind = .request
    envelope.requestID = 1
    envelope.payloadType = .clientHello
    envelope.payload = try hello.serializedData()

    let decodedEnvelope = try Droidmatch_V1_RpcEnvelope(serializedBytes: envelope.serializedData())
    let decodedHello = try Droidmatch_V1_ClientHello(serializedBytes: decodedEnvelope.payload)

    #expect(decodedEnvelope.frameVersion == 1)
    #expect(decodedEnvelope.kind == .request)
    #expect(decodedEnvelope.payloadType == .clientHello)
    #expect(decodedHello.clientName == hello.clientName)
    #expect(decodedHello.protocolMajor == 1)
    #expect(decodedHello.transport == .adb)
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

@Test func adbForwardParserHandlesAllocatedPortOutput() {
    #expect(AdbClient.parseAllocatedForwardPort("49152\n") == 49152)
    #expect(AdbClient.parseAllocatedForwardPort("\n\t49152  \n") == 49152)
    #expect(AdbClient.parseAllocatedForwardPort("* daemon started successfully\n49152\n") == 49152)
    #expect(AdbClient.parseAllocatedForwardPort("") == nil)
    #expect(AdbClient.parseAllocatedForwardPort("not-a-port") == nil)
}

@Test func adbForwardParserFindsExistingDynamicForward() {
    let forwards = [
        AdbForward(serial: "ABC123", local: "tcp:49152", remote: "tcp:39001"),
        AdbForward(serial: "ABC123", local: "localabstract:droidmatch", remote: "tcp:39002"),
        AdbForward(serial: "XYZ", local: "tcp:49153", remote: "tcp:39001")
    ]

    #expect(AdbClient.findForwardedTcpPort(in: forwards, serial: "ABC123", remotePort: 39001) == 49152)
    #expect(AdbClient.findForwardedTcpPort(in: forwards, serial: "ABC123", remotePort: 39002) == nil)
    #expect(AdbClient.findForwardedTcpPort(in: forwards, serial: "MISSING", remotePort: 39001) == nil)
}

@Test func framedTcpClientRoundTripsAgainstLocalEchoServer() throws {
    let server = try LocalFrameTestServer(handler: LocalFrameTestServer.echoOneFrame)
    defer {
        server.cancel()
    }

    let payload = Data("loopback-echo".utf8)
    let client = FramedTcpClient(port: server.port, timeoutSeconds: 2)
    #expect(try client.roundTrip(payload: payload) == payload)
}

@Test func framedTcpClientPerformsClientHelloServerHelloHandshake() throws {
    let server = try LocalFrameTestServer(handler: LocalFrameTestServer.replyWithServerHello)
    defer {
        server.cancel()
    }

    let result = try HandshakeSmokeClient().run(port: server.port, timeoutSeconds: 2)

    #expect(result.serverName == "LocalFrameTestServer")
    #expect(result.serverVersion == "test")
    #expect(result.protocolMajor == 1)
    #expect(result.transport == .adb)
    #expect(result.grantedCapabilities == [.diagnostics])
}

@Test func m1SmokeClientRunsHandshakeDeviceInfoDiagnosticsOnOneConnection() throws {
    let server = try LocalFrameTestServer(handler: LocalFrameTestServer.replyToM1SmokeRequests)
    defer {
        server.cancel()
    }

    let result = try M1SmokeClient().run(port: server.port, timeoutSeconds: 2)

    #expect(result.handshake.serverName == "LocalFrameTestServer")
    #expect(result.deviceInfo.manufacturer == "DroidMatch")
    #expect(result.deviceInfo.model == "Loopback")
    #expect(result.deviceInfo.sdkInt == 35)
    #expect(result.deviceInfo.permissions["media_read"] == .granted)
    #expect(result.diagnostics.transport == .adb)
    #expect(result.diagnostics.serviceState == "rpc.session.open")
    #expect(result.diagnostics.recentEvents.contains("state:rpc.session.open"))
}

@Test func framedTcpClientTimesOutWhenServerDoesNotReply() throws {
    let server = try LocalFrameTestServer { _ in }
    defer {
        server.cancel()
    }

    let client = FramedTcpClient(port: server.port, timeoutSeconds: 0.2)
    var sawReadHeaderTimeout = false
    do {
        _ = try client.roundTrip(payload: Data("no-reply".utf8))
    } catch let FramedTcpClientError.timedOut(stage, _) {
        sawReadHeaderTimeout = stage == "reading frame header"
    } catch {
        sawReadHeaderTimeout = false
    }

    #expect(sawReadHeaderTimeout)
}

@Test func framedTcpClientRejectsEmptyFrameFromServer() throws {
    let server = try LocalFrameTestServer(handler: LocalFrameTestServer.sendEmptyFrameHeader)
    defer {
        server.cancel()
    }

    let client = FramedTcpClient(port: server.port, timeoutSeconds: 1)
    #expect(throws: FrameCodecError.emptyFrame) {
        _ = try client.roundTrip(payload: Data("bad-frame".utf8))
    }
}

private enum LocalEchoServerError: Error {
    case listenerDidNotBecomeReady
    case missingPort
    case unexpectedPayloadType
}

private final class LocalFrameTestServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "app.droidmatch.tests.local-framed-echo")

    let port: Int

    init(handler: @escaping @Sendable (NWConnection) -> Void) throws {
        listener = try NWListener(using: .tcp, on: .any)
        let ready = DispatchSemaphore(value: 0)

        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed:
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [queue] connection in
            connection.start(queue: queue)
            handler(connection)
        }
        listener.start(queue: queue)

        guard ready.wait(timeout: .now() + 2) == .success else {
            throw LocalEchoServerError.listenerDidNotBecomeReady
        }
        guard let rawPort = listener.port?.rawValue else {
            throw LocalEchoServerError.missingPort
        }
        port = Int(rawPort)
    }

    func cancel() {
        listener.cancel()
    }

    static func echoOneFrame(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { header, _, _, _ in
            guard let header, header.count == 4 else {
                connection.cancel()
                return
            }
            let length = (UInt32(header[0]) << 24)
                | (UInt32(header[1]) << 16)
                | (UInt32(header[2]) << 8)
                | UInt32(header[3])
            guard length > 0, length <= UInt32(FrameCodec.defaultMaxEnvelopeLength) else {
                connection.cancel()
                return
            }
            connection.receive(minimumIncompleteLength: Int(length), maximumLength: Int(length)) { body, _, _, _ in
                guard let body, body.count == Int(length) else {
                    connection.cancel()
                    return
                }
                var frame = Data()
                frame.append(header)
                frame.append(body)
                connection.send(content: frame, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
    }

    static func replyWithServerHello(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { header, _, _, _ in
            guard let header, header.count == 4 else {
                connection.cancel()
                return
            }
            let length = (UInt32(header[0]) << 24)
                | (UInt32(header[1]) << 16)
                | (UInt32(header[2]) << 8)
                | UInt32(header[3])
            guard length > 0, length <= UInt32(FrameCodec.defaultMaxEnvelopeLength) else {
                connection.cancel()
                return
            }
            connection.receive(minimumIncompleteLength: Int(length), maximumLength: Int(length)) { body, _, _, _ in
                guard let body, body.count == Int(length) else {
                    connection.cancel()
                    return
                }
                guard let response = try? handshakeResponse(to: body),
                      let frame = try? FrameCodec().encode(payload: response) else {
                    connection.cancel()
                    return
                }
                connection.send(content: frame, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
    }

    static func replyToM1SmokeRequests(on connection: NWConnection) {
        readM1SmokeRequest(on: connection)
    }

    static func sendEmptyFrameHeader(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { _, _, _, _ in
            connection.send(content: Data([0, 0, 0, 0]), completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private static func readM1SmokeRequest(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { header, _, _, _ in
            guard let header, header.count == 4 else {
                connection.cancel()
                return
            }
            let length = (UInt32(header[0]) << 24)
                | (UInt32(header[1]) << 16)
                | (UInt32(header[2]) << 8)
                | UInt32(header[3])
            guard length > 0, length <= UInt32(FrameCodec.defaultMaxEnvelopeLength) else {
                connection.cancel()
                return
            }
            connection.receive(minimumIncompleteLength: Int(length), maximumLength: Int(length)) { body, _, _, _ in
                guard let body, body.count == Int(length) else {
                    connection.cancel()
                    return
                }
                guard let response = try? m1SmokeResponse(to: body),
                      let frame = try? FrameCodec().encode(payload: response.payload) else {
                    connection.cancel()
                    return
                }
                connection.send(content: frame, completion: .contentProcessed { _ in
                    if response.isFinal {
                        connection.cancel()
                    } else {
                        readM1SmokeRequest(on: connection)
                    }
                })
            }
        }
    }

    private static func handshakeResponse(to requestBody: Data) throws -> Data {
        let request = try Droidmatch_V1_RpcEnvelope(serializedBytes: requestBody)
        let clientHello = try Droidmatch_V1_ClientHello(serializedBytes: request.payload)

        var serverHello = Droidmatch_V1_ServerHello()
        serverHello.serverName = "LocalFrameTestServer"
        serverHello.serverVersion = "test"
        serverHello.protocolMajor = 1
        serverHello.protocolMinor = min(clientHello.protocolMinor, 0)
        serverHello.transport = .adb
        if clientHello.requestedCapabilities.contains(.diagnostics) {
            serverHello.grantedCapabilities = [.diagnostics]
        }

        var response = Droidmatch_V1_RpcEnvelope()
        response.frameVersion = 1
        response.kind = .response
        response.requestID = request.requestID
        response.payloadType = .serverHello
        response.payload = try serverHello.serializedData()
        return try response.serializedData()
    }

    private static func m1SmokeResponse(to requestBody: Data) throws -> LocalControlPlaneResponse {
        let request = try Droidmatch_V1_RpcEnvelope(serializedBytes: requestBody)
        var response = Droidmatch_V1_RpcEnvelope()
        response.frameVersion = 1
        response.kind = .response
        response.requestID = request.requestID

        switch request.payloadType {
        case .clientHello:
            return LocalControlPlaneResponse(
                payload: try handshakeResponse(to: requestBody),
                isFinal: false
            )
        case .deviceInfoRequest:
            _ = try Droidmatch_V1_DeviceInfoRequest(serializedBytes: request.payload)
            var deviceInfo = Droidmatch_V1_DeviceInfoResponse()
            deviceInfo.deviceID = "loopback-test"
            deviceInfo.manufacturer = "DroidMatch"
            deviceInfo.model = "Loopback"
            deviceInfo.androidVersion = "15"
            deviceInfo.sdkInt = 35
            deviceInfo.totalStorageBytes = 1024
            deviceInfo.freeStorageBytes = 512
            deviceInfo.batteryPercent = 87
            deviceInfo.permissions = ["media_read": .granted]
            response.payloadType = .deviceInfoResponse
            response.payload = try deviceInfo.serializedData()
            return LocalControlPlaneResponse(payload: try response.serializedData(), isFinal: false)
        case .diagnosticsRequest:
            _ = try Droidmatch_V1_DiagnosticsRequest(serializedBytes: request.payload)
            var diagnostics = Droidmatch_V1_DiagnosticsResponse()
            diagnostics.transport = .adb
            diagnostics.serviceState = "rpc.session.open"
            diagnostics.recentErrors = ["error:example"]
            diagnostics.counters = ["rpc.frames.received": "3"]
            diagnostics.recentEvents = ["state:rpc.session.open", "state:permission.media_read:GRANTED"]
            response.payloadType = .diagnosticsResponse
            response.payload = try diagnostics.serializedData()
            return LocalControlPlaneResponse(payload: try response.serializedData(), isFinal: true)
        default:
            throw LocalEchoServerError.unexpectedPayloadType
        }
    }
}

private struct LocalControlPlaneResponse {
    let payload: Data
    let isFinal: Bool
}
