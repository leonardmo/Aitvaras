import Foundation
import Testing
@testable import AitvarasAgents

@Suite(.timeLimit(.minutes(2))) struct AgentConversationTextTests {
    @Test func quotingUsesSelectionOrTheWholeAnswerAndPreservesBlankLines() {
        #expect(AgentConversationText.quote("First\n\nLast") == "> First\n> \n> Last")
        #expect(AgentConversationText.quote("Whole", selection: "Selected\r\nlines") == "> Selected\n> lines")
        #expect(AgentConversationText.quote("Whole", selection: "") == "> Whole")
        #expect(AgentConversationText.appending("> Quote", to: "Draft") == "Draft\n\n> Quote\n\n")
        #expect(AgentConversationText.sideQuestion(in: "/btw question") == "question")
        #expect(AgentConversationText.sideQuestion(in: "/btw") == "")
        #expect(AgentConversationText.sideQuestion(in: "/btw\tquestion") == "question")
        #expect(AgentConversationText.sideQuestion(in: "/btw\r\nquestion") == "question")
        #expect(AgentConversationText.sideQuestion(in: "/btwhatever") == nil)
    }

    @Test func hunkRangesUseNewLinesAndOldLinesForRemovedOnlySelections() throws {
        let diff = "--- a/example.swift\n+++ b/example.swift\n@@ -10,3 +20,4 @@\n context\n-old\n+new\n+extra\n end\n"
        let lines = AgentDiffContext.lines(diff)
        #expect(lines[3].oldLine == 10 && lines[3].newLine == 20)
        #expect(lines[4].oldLine == 11 && lines[4].newLine == nil)
        #expect(lines[5].newLine == 21 && lines[6].newLine == 22 && lines[7].newLine == 23)
        let mixed = try #require(AgentDiffContext.message(path: "example.swift", diff: diff, selected: [4, 5, 6]))
        #expect(mixed == "example.swift:L21-L22\n```\n-old\n+new\n+extra\n```")
        #expect(AgentDiffContext.message(path: "example.swift", diff: diff, selected: [4]) == "example.swift:L11-L11\n```\n-old\n```")
        #expect(AgentDiffContext.message(path: "example.swift", diff: diff, selected: [0, 1, 2]) == nil)
    }

    @Test func separateHunksAndNoncontiguousSelectionsNeverIncludeUnselectedLines() throws {
        let diff = "@@ -1 +1 @@\n-first\n+second\n@@ -40,0 +41,2 @@\n+```\n+last\n\\ No newline at end of file"
        let value = try #require(AgentDiffContext.message(path: "example.txt", diff: diff, selected: [1, 4, 5]))
        #expect(value.hasPrefix("example.txt:L1-L1\n```\n-first\n```"))
        #expect(value.contains("example.txt:L41-L42\n````\n+```\n+last\n````"))
        #expect(!value.contains("second"))
        #expect(!value.contains("No newline"))
        #expect(AgentDiffContext.message(path: "example.txt", diff: "Binary file", selected: [0]) == nil)
    }
}
