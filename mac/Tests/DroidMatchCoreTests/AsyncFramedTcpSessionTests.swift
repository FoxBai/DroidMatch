import Foundation
import Testing
@testable import DroidMatchCore

@Test func asyncFramedTcpSessionRoundTripsWithoutBlocking() async throws {
    let server = try LocalFrameTestServer(handler: LocalFrameTestServer.echoOneFrame)
    defer {
        server.cancel()
    }

    let session = try await AsyncFramedTcpSession.connect(
        port: server.port,
        timeoutSeconds: 2
    )
    let payload = Data("async-loopback-echo".utf8)

    do {
        #expect(try await session.roundTrip(payload: payload) == payload)
        await session.close()
    } catch {
        await session.close()
        throw error
    }
}

@Test func asyncFramedTcpSessionRejectsInvalidTimeoutBeforeConnecting() async {
    for timeout in [0, -1, .nan, .infinity] {
        await #expect(throws: FramedTcpClientError.self) {
            _ = try await AsyncFramedTcpSession.connect(
                port: 1,
                timeoutSeconds: timeout
            )
        }
    }
}

@Test func asyncFramedTcpSessionSerializesConcurrentRoundTrips() async throws {
    let server = try LocalFrameTestServer { connection in
        LocalFrameTestServer.echoFrames(2, on: connection)
    }
    defer {
        server.cancel()
    }

    let session = try await AsyncFramedTcpSession.connect(
        port: server.port,
        timeoutSeconds: 2
    )
    let firstPayload = Data("first-concurrent-request".utf8)
    let secondPayload = Data("second-concurrent-request".utf8)

    do {
        async let first = session.roundTrip(payload: firstPayload)
        async let second = session.roundTrip(payload: secondPayload)
        let (firstResponse, secondResponse) = try await (first, second)

        #expect(firstResponse == firstPayload)
        #expect(secondResponse == secondPayload)
        await session.close()
    } catch {
        await session.close()
        throw error
    }
}

@Test func asyncFramedTcpSessionTimesOutAndClosesAmbiguousSession() async throws {
    let server = try LocalFrameTestServer { _ in }
    defer {
        server.cancel()
    }

    let session = try await AsyncFramedTcpSession.connect(
        port: server.port,
        timeoutSeconds: 0.2
    )
    var sawReadHeaderTimeout = false

    do {
        _ = try await session.roundTrip(payload: Data("no-async-reply".utf8))
    } catch let FramedTcpClientError.timedOut(stage, _) {
        sawReadHeaderTimeout = stage == "reading frame header"
    } catch {
        sawReadHeaderTimeout = false
    }

    #expect(sawReadHeaderTimeout)
    await session.close()
}

@Test func asyncFramedTcpSessionCancellationCancelsReceive() async throws {
    let server = try LocalFrameTestServer { _ in }
    defer {
        server.cancel()
    }

    let session = try await AsyncFramedTcpSession.connect(
        port: server.port,
        timeoutSeconds: 5
    )
    let request = Task {
        try await session.roundTrip(payload: Data("cancel-async-receive".utf8))
    }

    try await Task.sleep(nanoseconds: 50_000_000)
    request.cancel()

    var sawCancellation = false
    do {
        _ = try await request.value
    } catch is CancellationError {
        sawCancellation = true
    } catch {
        sawCancellation = false
    }

    #expect(sawCancellation)
    await session.close()
}

@Test func cancellingQueuedRoundTripDoesNotCancelActiveSession() async throws {
    let server = try LocalFrameTestServer { connection in
        LocalFrameTestServer.echoFrames(2, delayBeforeResponse: 0.2, on: connection)
    }
    defer {
        server.cancel()
    }

    let session = try await AsyncFramedTcpSession.connect(
        port: server.port,
        timeoutSeconds: 2
    )
    let activePayload = Data("active-request".utf8)
    let cancelledPayload = Data("cancelled-queued-request".utf8)
    let followUpPayload = Data("follow-up-request".utf8)

    let activeRequest = Task {
        try await session.roundTrip(payload: activePayload)
    }
    try await Task.sleep(nanoseconds: 25_000_000)
    let queuedRequest = Task {
        try await session.roundTrip(payload: cancelledPayload)
    }
    try await Task.sleep(nanoseconds: 25_000_000)
    queuedRequest.cancel()

    var queuedRequestWasCancelled = false
    do {
        _ = try await queuedRequest.value
    } catch is CancellationError {
        queuedRequestWasCancelled = true
    } catch {
        queuedRequestWasCancelled = false
    }

    do {
        #expect(queuedRequestWasCancelled)
        #expect(try await activeRequest.value == activePayload)
        #expect(try await session.roundTrip(payload: followUpPayload) == followUpPayload)
        await session.close()
    } catch {
        await session.close()
        throw error
    }
}

@Test func asyncFramedSessionRejectsMultiplexingAfterRoundTripMode() async throws {
    let server = try LocalFrameTestServer(handler: LocalFrameTestServer.echoOneFrame)
    defer { server.cancel() }
    let session = try await AsyncFramedTcpSession.connect(
        port: server.port,
        timeoutSeconds: 2
    )

    _ = try await session.roundTrip(payload: Data("select-round-trip".utf8))
    let multiplexer = AsyncRpcMultiplexer(session: session, requestTimeoutSeconds: 2)
    var rejected = false
    do {
        try await multiplexer.start()
    } catch AsyncFramedTcpSessionModeError.incompatibleAccessMode {
        rejected = true
    }
    #expect(rejected)
    await session.close()
}

@Test func asyncFramedSessionRejectsRoundTripAfterMultiplexingMode() async throws {
    let server = try LocalFrameTestServer { _ in }
    defer { server.cancel() }
    let session = try await AsyncFramedTcpSession.connect(
        port: server.port,
        timeoutSeconds: 2
    )
    let multiplexer = AsyncRpcMultiplexer(session: session, requestTimeoutSeconds: 2)
    try await multiplexer.start()

    var rejected = false
    do {
        _ = try await session.roundTrip(payload: Data("must-not-send".utf8))
    } catch AsyncFramedTcpSessionModeError.incompatibleAccessMode {
        rejected = true
    }
    #expect(rejected)
    await multiplexer.close()
}
