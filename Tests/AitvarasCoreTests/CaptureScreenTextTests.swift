import Testing
import AitvarasCore

@Suite struct CaptureScreenTextTests {
    @Test func exportsOCRWithoutDuplicatingSpeech() {
        let text = "[00:00:01] [Mikrofon] First phrase\n[00:00:02] [Bildschirm]\nTitle\nFormula\n[00:00:03] [Systemaudio] Second phrase\n[00:00:05] [Bildschirm]\nNext slide"
        #expect(CaptureScreenText.extract(from: text) == "[00:00:02] [Bildschirm]\nTitle\nFormula\n[00:00:05] [Bildschirm]\nNext slide")
    }
    @Test func audioOnlyHasNoScreenExcerpt() {
        #expect(CaptureScreenText.extract(from: "[00:00:01] [Mikrofon] Speech") == "")
    }
    @Test func wordsMentioningScreenInsideSpeechDoNotBecomeOCR() {
        #expect(CaptureScreenText.extract(from: "[00:00:01] [Mikrofon] The tag [Bildschirm] is an example.") == "")
        #expect(CaptureScreenText.extract(from: "[00:00:01] [Mikrofon] [Bildschirm]") == "")
    }
}
