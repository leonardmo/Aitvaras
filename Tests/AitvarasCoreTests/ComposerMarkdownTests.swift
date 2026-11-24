import Foundation
import Testing
import AitvarasAgents

struct ComposerMarkdownTests {
    @Test func liveStylesUseSourceOffsetsAndKeepMarkersInCodeLiteral() {
        let text = "# Draft\n\n- **Strong** item\n2. Two\n\n```sh\n- literal\n```"
        let draft = ComposerMarkdown(text)
        let source = text as NSString
        #expect(draft.source == text)
        #expect(draft.spans.filter { $0.style == .bullet }.map { source.substring(with: $0.range) } == ["-"])
        #expect(draft.spans.filter { $0.style == .ordered }.map { source.substring(with: $0.range) } == ["2."])
        #expect(draft.spans.filter { $0.style == .strong }.map { source.substring(with: $0.range) } == ["Strong"])
        #expect(draft.spans.contains { $0.style == .heading(1) })
    }

    @Test func returnContinuesAnOrderedListInUTF16CoordinatesAndExitsEmptyItem() throws {
        let source = "7. 🐉"
        let selection = AgentComposerCaret.afterInsertion(source)
        let inserted = try #require(ComposerMarkdown(source).newlineEdit(at: selection))
        #expect(inserted.range == selection)
        #expect(inserted.text == "\n8. ")

        let withEmptyItem = source + inserted.text
        let emptyEdit = try #require(ComposerMarkdown(withEmptyItem).newlineEdit(at: AgentComposerCaret.afterInsertion(withEmptyItem)))
        #expect(emptyEdit.text.isEmpty)
        #expect((withEmptyItem as NSString).substring(with: emptyEdit.range) == "8. ")
        #expect(ComposerMarkdown("normal text").newlineEdit(at: NSRange(location: 11, length: 0)) == nil)
    }

    @Test func returnInsideUnclosedCodeFenceDoesNotContinueAList() throws {
        let source = "```sh\n- example"
        let edit = try #require(ComposerMarkdown(source).newlineEdit(at: AgentComposerCaret.afterInsertion(source)))
        #expect(edit.text == "\n")
    }
}
