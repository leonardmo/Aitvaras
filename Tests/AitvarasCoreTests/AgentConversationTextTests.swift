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
        #expect(mixed == "example.swift:L21-L22\n```\nnew\nextra\n```")
        #expect(AgentDiffContext.message(path: "example.swift", diff: diff, selected: [3, 4, 5, 6, 7]) == "example.swift:L20-L23\n```\ncontext\nnew\nextra\nend\n```")
        #expect(AgentDiffContext.message(path: "example.swift", diff: diff, selected: [4]) == "example.swift:L11-L11\n```\n-old\n```")
        #expect(AgentDiffContext.message(path: "example.swift", diff: diff, selected: [0, 1, 2]) == nil)
    }

    @Test func separateHunksAndNoncontiguousSelectionsNeverIncludeUnselectedLines() throws {
        let diff = "@@ -1 +1 @@\n-first\n+second\n@@ -40,0 +41,2 @@\n+```\n+last\n\\ No newline at end of file"
        let value = try #require(AgentDiffContext.message(path: "example.txt", diff: diff, selected: [1, 4, 5]))
        #expect(value == "example.txt:L41-L42\n````\n```\nlast\n````")
        #expect(!value.contains("second"))
        #expect(!value.contains("No newline"))
        #expect(AgentDiffContext.message(path: "example.txt", diff: "Binary file", selected: [0]) == nil)
    }

    @Test func shiftAndDragRangesKeepTheirAnchorWithinOneHunk() {
        let lines = AgentDiffContext.lines("@@ -1,3 +1,3 @@\n first\n second\n third\n@@ -10 +10 @@\n last")
        var selection = AgentDiffSelection()
        selection.select(1, in: lines)
        selection.select(3, in: lines, extending: true)
        #expect(selection.selected == [1, 2, 3])
        #expect(selection.anchor == 1)
        selection.select(2, in: lines, extending: true)
        #expect(selection.selected == [1, 2])
        selection.select(5, in: lines, extending: true)
        #expect(selection.selected == [1, 2])
        selection.select(999, in: lines)
        selection.select(0, in: lines)
        #expect(selection.selected == [1, 2])
        selection.select(3, in: lines)
        selection.select(1, in: lines, extending: true)
        #expect(selection.selected == [1, 2, 3])
        #expect(selection.anchor == 3)
        selection.select(2, in: lines, toggling: true)
        #expect(selection.selected == [1, 3])
        selection = .init()
        selection.select(5, in: lines, extending: true)
        #expect(selection.selected == [5])
    }

    @Test func snippetsPreserveFileIndentationAndLiteralMarkerCharacters() {
        let diff = "@@ -1,2 +1,3 @@\n-removed\n+  indented\n++literal plus\n -literal minus"
        #expect(AgentDiffContext.message(path: "example.txt", diff: diff, selected: [1, 2, 3, 4]) == "example.txt:L1-L3\n```\n  indented\n+literal plus\n-literal minus\n```")
        #expect(AgentDiffContext.message(path: "example.txt", diff: diff, selected: [1]) == "example.txt:L1-L1\n```\n-removed\n```")
    }
}
