import Testing
@testable import VoiceInk

struct EnhancementFailureTextTests {
    @Test func recognizesStoredFailureMessages() {
        let stored = EnhancementFailureFormatter.message(description: "Request timed out.")

        #expect(EnhancementFailureFormatter.isFailureMessage(stored))
        #expect(EnhancementFailureFormatter.isFailureMessage("  Enhancement failed: HTTP 500"))
    }

    @Test func acceptsOrdinaryText() {
        #expect(!EnhancementFailureFormatter.isFailureMessage("Assessment: enhancement failed to improve symptoms."))
        #expect(!EnhancementFailureFormatter.isFailureMessage(""))
    }

    @Test func fallsBackToOriginalTextAfterFailedEnhancement() {
        let transcription = Transcription(
            text: "raw dictation",
            duration: 3,
            enhancedText: EnhancementFailureFormatter.message(description: "Timed out.")
        )

        #expect(transcription.usableEnhancedText == nil)

        transcription.enhancedText = "Clean note."
        #expect(transcription.usableEnhancedText == "Clean note.")
    }
}
