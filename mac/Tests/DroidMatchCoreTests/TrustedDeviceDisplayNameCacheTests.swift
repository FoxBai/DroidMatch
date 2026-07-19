@testable import DroidMatchCore
import Foundation
import Testing

@Test func trustedDeviceDisplayNameCacheBoundsTextAndRejectsInvalidCorrelationKeys() async throws {
    let cache = TrustedDeviceDisplayNameCache()
    let pairingID = Data(repeating: 0x31, count: PairingAuthenticator.pairingIDLength)

    await cache.remember(" \u{202E}シンプル\nスマホ4\u{2069} ", for: pairingID)
    #expect(await cache.displayName(for: pairingID) == "シンプル スマホ4")

    await cache.remember("replacement", for: Data())
    await cache.remember(String(repeating: "界", count: 80), for: pairingID)
    let boundedName = try #require(await cache.displayName(for: pairingID))
    #expect(Data(boundedName.utf8).count
            <= PairingAuthenticator.maximumDisplayNameBytes)
    #expect(boundedName.hasSuffix("…"))

    await cache.forget(pairingID: Data())
    #expect(await cache.displayName(for: pairingID) == boundedName)
    await cache.forget(pairingID: pairingID)
    #expect(await cache.displayName(for: pairingID) == nil)
    await cache.remember("late authenticated name", for: pairingID)
    #expect(await cache.displayName(for: pairingID) == nil)
}
