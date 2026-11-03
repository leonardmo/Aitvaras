import Testing
@testable import AitvarasCore

@Suite struct StableIdentifierTests {
    @Test func digestIsDeterministicAndDoesNotExposeInput() {
        let first = StableIdentifier.digest(["private/path", "A title"])
        let second = StableIdentifier.digest(["private/path", "A title"])

        #expect(first == second)
        #expect(first.count == 64)
        #expect(!first.contains("private"))
    }

    @Test func componentBoundariesCannotCollideByConcatenation() {
        #expect(StableIdentifier.digest(["ab", "c"]) != StableIdentifier.digest(["a", "bc"]))
    }

    @Test func shortDigestHasRequestedBoundedLength() {
        #expect(StableIdentifier.short(["value"], length: 20).count == 20)
        #expect(StableIdentifier.short(["value"], length: 100).count == 64)
        #expect(StableIdentifier.short(["value"], length: 0).count == 1)
    }
}
