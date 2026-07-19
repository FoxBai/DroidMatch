import Testing
@testable import DroidMatchPresentation

@Test func mediaDurationTextRendersBoundedClockValues() {
    #expect(MediaDurationText.value(nil) == nil)
    #expect(MediaDurationText.value(0) == nil)
    #expect(MediaDurationText.value(-1) == nil)
    #expect(MediaDurationText.value(999) == "0:00")
    #expect(MediaDurationText.value(65_999) == "1:05")
    #expect(MediaDurationText.value(3_723_999) == "1:02:03")
    #expect(MediaDurationText.value(Int64.max) == "2562047788015:12:55")
}
