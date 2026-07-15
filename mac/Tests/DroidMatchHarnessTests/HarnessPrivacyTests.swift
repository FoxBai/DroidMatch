import Testing
import DroidMatchCore
@testable import DroidMatchHarness

@Test func harnessPrivacyRedactsPathsAndMessages() {
    #expect(HarnessPrivacy.path("/Users/alice/Documents/private.txt") == "<path-redacted>")
    #expect(HarnessPrivacy.path("dm://app-sandbox/private.txt") == "<path-redacted>")
    #expect(HarnessPrivacy.message("private provider detail") == "<message-redacted>")
}

@Test func harnessPrivacyKeepsHarnessErrorDescriptionsBounded() {
    let error = HarnessError.resumeSourceChanged("/Users/alice/Documents/private.txt")

    #expect(HarnessPrivacy.errorLabel(error) == "resume metadata source file changed: <path-redacted>")
    #expect(!HarnessPrivacy.errorLabel(error).contains("private.txt"))
    #expect(HarnessPrivacy.errorLabel(HarnessError.invalidHex("deadbeef-private")) == "invalid hex payload")
}

@Test func harnessPrivacyLabelsUnknownErrorsByTypeOnly() {
    struct PrivateError: Error, CustomStringConvertible {
        var description: String { "/Users/alice/private.txt" }
    }

    let label = HarnessPrivacy.errorLabel(PrivateError())

    #expect(label == "<error:PrivateError>")
    #expect(!label.contains("private.txt"))
}

@Test func harnessPrivacyKeepsRemoteErrorCodeWithoutProviderMessage() {
    var remoteError = Droidmatch_V1_DroidMatchError()
    remoteError.code = .notFound
    remoteError.message = "/private/provider/path"

    let label = HarnessPrivacy.errorLabel(RpcControlClientError.remoteError(remoteError))

    #expect(label.contains("notFound"))
    #expect(!label.contains("provider"))
    #expect(!label.contains("/private"))
}

@Test func harnessPrivacyLabelsDirectoryMutationFailureWithoutPath() {
    let label = HarnessPrivacy.errorLabel(
        DirectoryMutationError.remote(.permissionRequired)
    )

    #expect(label == "remote mutation error: permissionRequired")
}

@Test func harnessPrivacyExplainsUnsafeDownloadDirectoryWithoutPath() {
    let label = HarnessPrivacy.errorLabel(
        AtomicDownloadWriterError.unsafeDestinationDirectory
    )

    #expect(label == "download destination parent must be a non-symlink directory")
    #expect(!label.contains("/tmp"))
}

@Test func harnessHelpUsesNonSymlinkDownloadDestinations() {
    #expect(HarnessHelp.usage.contains("--destination /private/tmp/"))
    #expect(HarnessHelp.usage.contains("--download-destination /private/tmp/"))
    #expect(!HarnessHelp.usage.contains("--destination /tmp/"))
    #expect(!HarnessHelp.usage.contains("--download-destination /tmp/"))
}
