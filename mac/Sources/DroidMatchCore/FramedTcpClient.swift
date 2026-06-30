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
        guard let portValue = UInt16(exactly: port), let nwPort = NWEndpoint.Port(rawValue: portValue) else {
            throw FramedTcpClientError.invalidPort(port)
        }

        let queue = DispatchQueue(label: "app.droidmatch.framed-tcp-client")
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        defer {
            connection.cancel()
        }

        try start(connection, queue: queue)
        try send(try codec.encode(payload: payload), on: connection)
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
            throw FramedTcpClientError.connectionClosed(stage: "decoding echoed frame")
        }
        return decoded
    }

    private func start(_ connection: NWConnection, queue: DispatchQueue) throws {
        let result = LockedResult<Void>()
        let semaphore = DispatchSemaphore(value: 0)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                result.complete(.success(()))
                semaphore.signal()
            case let .failed(error):
                result.complete(.failure(FramedTcpClientError.connectionFailed(error.localizedDescription)))
                semaphore.signal()
            case .cancelled:
                result.complete(.failure(FramedTcpClientError.connectionClosed(stage: "connect")))
                semaphore.signal()
            default:
                break
            }
        }

        connection.start(queue: queue)
        guard semaphore.wait(timeout: .now() + timeoutSeconds) == .success else {
            throw FramedTcpClientError.timedOut(stage: "connect", seconds: timeoutSeconds)
        }
        try result.value().get()
    }

    private func send(_ data: Data, on connection: NWConnection) throws {
        let result = LockedResult<Void>()
        let semaphore = DispatchSemaphore(value: 0)
        connection.send(content: data, completion: .contentProcessed { error in
            if let error {
                result.complete(.failure(FramedTcpClientError.connectionFailed(error.localizedDescription)))
            } else {
                result.complete(.success(()))
            }
            semaphore.signal()
        })

        guard semaphore.wait(timeout: .now() + timeoutSeconds) == .success else {
            throw FramedTcpClientError.timedOut(stage: "send", seconds: timeoutSeconds)
        }
        try result.value().get()
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
        let result = LockedResult<Data>()
        let semaphore = DispatchSemaphore(value: 0)
        connection.receive(minimumIncompleteLength: 1, maximumLength: maxLength) { content, _, isComplete, error in
            if let error {
                result.complete(.failure(FramedTcpClientError.connectionFailed(error.localizedDescription)))
            } else if let content, !content.isEmpty {
                result.complete(.success(content))
            } else if isComplete {
                result.complete(.failure(FramedTcpClientError.connectionClosed(stage: stage)))
            } else {
                result.complete(.success(Data()))
            }
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + timeoutSeconds) == .success else {
            throw FramedTcpClientError.timedOut(stage: stage, seconds: timeoutSeconds)
        }
        return try result.value().get()
    }
}

private final class LockedResult<Success>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Success, Error>?

    func complete(_ newResult: Result<Success, Error>) {
        lock.lock()
        if result == nil {
            result = newResult
        }
        lock.unlock()
    }

    func value() -> Result<Success, Error> {
        lock.lock()
        let current = result
        lock.unlock()
        return current ?? .failure(FramedTcpClientError.connectionClosed(stage: "waiting for result"))
    }
}
