import Foundation
import Network

public enum FramedTcpClientError: Error, CustomStringConvertible {
    case invalidPort(Int)
    case timedOut(stage: String, seconds: TimeInterval)
    case connectionFailed(String)
    case connectionClosed(stage: String)

    public var description: String {
        switch self {
        case let .invalidPort(port):
            return "invalid TCP port: \(port)"
        case let .timedOut(stage, seconds):
            return "\(stage) timed out after \(seconds)s"
        case let .connectionFailed(message):
            return "connection failed: \(message)"
        case let .connectionClosed(stage):
            return "connection closed while \(stage)"
        }
    }
}

public final class FramedTcpClient {
    private let host: String
    private let port: Int
    private let timeoutSeconds: TimeInterval
    private let codec: FrameCodec

    public init(
        host: String = "127.0.0.1",
        port: Int,
        timeoutSeconds: TimeInterval = 5,
        codec: FrameCodec = FrameCodec()
    ) {
        self.host = host
        self.port = port
        self.timeoutSeconds = timeoutSeconds
        self.codec = codec
    }

    public func roundTrip(payload: Data) throws -> Data {
        let session = try FramedTcpSession(
            host: host,
            port: port,
            timeoutSeconds: timeoutSeconds,
            codec: codec
        )
        defer {
            session.close()
        }
        return try session.roundTrip(payload: payload)
    }
}

public final class FramedTcpSession {
    private let timeoutSeconds: TimeInterval
    private let codec: FrameCodec
    private let queue = DispatchQueue(label: "app.droidmatch.framed-tcp-session")
    private let connection: NWConnection

    public init(
        host: String = "127.0.0.1",
        port: Int,
        timeoutSeconds: TimeInterval = 5,
        codec: FrameCodec = FrameCodec()
    ) throws {
        guard let portValue = UInt16(exactly: port), let nwPort = NWEndpoint.Port(rawValue: portValue) else {
            throw FramedTcpClientError.invalidPort(port)
        }

        self.timeoutSeconds = timeoutSeconds
        self.codec = codec
        self.connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)

        try start()
    }

    deinit {
        close()
    }

    public func close() {
        connection.cancel()
    }

    public func roundTrip(payload: Data) throws -> Data {
        try sendPayload(payload)
        return try receivePayload()
    }

    public func sendPayload(_ payload: Data) throws {
        try send(try codec.encode(payload: payload))
    }

    public func receivePayload() throws -> Data {
        let header = try receiveExact(4, from: connection, stage: "reading frame header")
        let length = (UInt32(header[0]) << 24)
            | (UInt32(header[1]) << 16)
            | (UInt32(header[2]) << 8)
            | UInt32(header[3])
        guard length > 0 else {
            throw FrameCodecError.emptyFrame
        }
        guard length <= UInt32(codec.maxEnvelopeLength) else {
            throw FrameCodecError.frameTooLarge(Int(length))
        }
        let body = try receiveExact(Int(length), from: connection, stage: "reading frame payload")
        var frame = Data()
        frame.append(header)
        frame.append(body)
        guard let decoded = try codec.decodeNext(from: &frame), frame.isEmpty else {
            throw FramedTcpClientError.connectionClosed(stage: "decoding response frame")
        }
        return decoded
    }

    private func start() throws {
        let result = LockedValue<Result<Void, Error>?>(nil)
        let semaphore = DispatchSemaphore(value: 0)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                Self.complete(result, with: .success(()))
                semaphore.signal()
            case let .failed(error):
                Self.complete(result, with: .failure(FramedTcpClientError.connectionFailed(error.localizedDescription)))
                semaphore.signal()
            case .cancelled:
                Self.complete(result, with: .failure(FramedTcpClientError.connectionClosed(stage: "connect")))
                semaphore.signal()
            default:
                break
            }
        }

        connection.start(queue: queue)
        guard semaphore.wait(timeout: .now() + timeoutSeconds) == .success else {
            throw FramedTcpClientError.timedOut(stage: "connect", seconds: timeoutSeconds)
        }
        try Self.resultValue(result, stage: "waiting for connect").get()
    }

    private func send(_ data: Data) throws {
        let result = LockedValue<Result<Void, Error>?>(nil)
        let semaphore = DispatchSemaphore(value: 0)
        connection.send(content: data, completion: .contentProcessed { error in
            if let error {
                Self.complete(result, with: .failure(FramedTcpClientError.connectionFailed(error.localizedDescription)))
            } else {
                Self.complete(result, with: .success(()))
            }
            semaphore.signal()
        })

        guard semaphore.wait(timeout: .now() + timeoutSeconds) == .success else {
            throw FramedTcpClientError.timedOut(stage: "send", seconds: timeoutSeconds)
        }
        try Self.resultValue(result, stage: "waiting for send").get()
    }

    private func receiveExact(_ byteCount: Int, from connection: NWConnection, stage: String) throws -> Data {
        var received = Data()
        while received.count < byteCount {
            let chunk = try receiveChunk(
                maxLength: byteCount - received.count,
                from: connection,
                stage: stage
            )
            if chunk.isEmpty {
                continue
            }
            received.append(chunk)
        }
        return received
    }

    private func receiveChunk(maxLength: Int, from connection: NWConnection, stage: String) throws -> Data {
        let result = LockedValue<Result<Data, Error>?>(nil)
        let semaphore = DispatchSemaphore(value: 0)
        connection.receive(minimumIncompleteLength: 1, maximumLength: maxLength) { content, _, isComplete, error in
            if let error {
                Self.complete(result, with: .failure(FramedTcpClientError.connectionFailed(error.localizedDescription)))
            } else if let content, !content.isEmpty {
                Self.complete(result, with: .success(content))
            } else if isComplete {
                Self.complete(result, with: .failure(FramedTcpClientError.connectionClosed(stage: stage)))
            } else {
                Self.complete(result, with: .success(Data()))
            }
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + timeoutSeconds) == .success else {
            throw FramedTcpClientError.timedOut(stage: stage, seconds: timeoutSeconds)
        }
        return try Self.resultValue(result, stage: "waiting for \(stage)").get()
    }

    private static func complete<Success>(
        _ result: LockedValue<Result<Success, Error>?>,
        with newResult: Result<Success, Error>
    ) {
        result.update { current in
            if current == nil {
                current = newResult
            }
        }
    }

    private static func resultValue<Success>(
        _ result: LockedValue<Result<Success, Error>?>,
        stage: String
    ) -> Result<Success, Error> {
        result.value() ?? .failure(FramedTcpClientError.connectionClosed(stage: stage))
    }
}
