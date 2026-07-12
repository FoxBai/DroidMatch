@_spi(DroidMatchAppSupport) @testable import DroidMatchCore
import Foundation
import Testing

@Test func localFileAccessOwnerUsesDomainSeparatedAuthenticatedFingerprint() throws {
    let fingerprint = Data((0..<32).map(UInt8.init))
    let owner = try #require(LocalFileAccessOwnerID(
        authenticatedDeviceFingerprint: fingerprint
    ))

    #expect(
        owner.storageKey
            == "73390c5e3c12cb70e7c24dfd3f90a471bd7ebb0e0b41ddf33fbea8c5d1f623e2"
    )
    #expect(String(describing: owner) == "<redacted-local-file-access-owner>")
    #expect(String(reflecting: owner) == "<redacted-local-file-access-owner>")
    var dumpOutput = ""
    dump(owner, to: &dumpOutput)
    #expect(!dumpOutput.contains(owner.storageKey))
    #expect(LocalFileAccessOwnerID(
        authenticatedDeviceFingerprint: Data(fingerprint.dropLast())
    ) == nil)
    #expect(LocalFileAccessOwnerID(
        authenticatedDeviceFingerprint: fingerprint + Data([0xff])
    ) == nil)
}

@Test func localFileAccessOwnersDifferForDifferentAuthenticatedFingerprints() throws {
    let first = try #require(LocalFileAccessOwnerID(
        authenticatedDeviceFingerprint: Data(repeating: 0x0a, count: 32)
    ))
    let second = try #require(LocalFileAccessOwnerID(
        authenticatedDeviceFingerprint: Data(repeating: 0x0b, count: 32)
    ))

    #expect(first != second)
    #expect(first.storageKey.count == 64)
    #expect(second.storageKey.count == 64)
}
