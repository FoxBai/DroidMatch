import Testing
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
