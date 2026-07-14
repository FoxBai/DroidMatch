import Testing
@testable import DroidMatchCore

@Test func connectionFailureDescriptionDoesNotExposePlatformText() {
    let privatePlatformText = "POSIX: /Users/alice/Private/device.sock"

    #expect(
        FramedTcpClientError.connectionFailed(privatePlatformText).description
            == "connection failed"
    )
    #expect(FramedTcpClientError.networkFailure.description == "connection failed")
}
