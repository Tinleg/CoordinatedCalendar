import CoordinatedCalendarCore
import Testing

@Test func tagsAndVersionsCompareNumerically() throws {
    let current = try #require(ReleaseVersion("0.2.0"))
    #expect(try #require(ReleaseVersion("v0.3.0")) > current)
    #expect(try #require(ReleaseVersion("v0.10.0")) > #require(ReleaseVersion("0.9.0")), "not compared as text")
    #expect(try #require(ReleaseVersion("v0.2.0")) == current, "the same release is not an update")
    #expect(try #require(ReleaseVersion("0.2")) == current, "a missing part counts as zero")
    #expect(try #require(ReleaseVersion("v0.1.2")) < current, "an older release is never offered")
}

@Test func onlyTheReleasePartOfATagCounts() throws {
    #expect(try #require(ReleaseVersion("v0.3.0-beta.1")) == #require(ReleaseVersion("0.3.0")))
}

@Test func somethingThatIsNotAVersionIsRejected() {
    #expect(ReleaseVersion("latest") == nil)
    #expect(ReleaseVersion("") == nil)
    #expect(ReleaseVersion("v1..2") == nil)
}
