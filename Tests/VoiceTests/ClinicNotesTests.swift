import Foundation
import Testing
@testable import Voice

struct CustomPromptCodingTests {
    @Test func decodesPromptsSavedBeforeTemplateFields() throws {
        let json = """
            {"id":"00000000-0000-0000-0000-0000000000AA","title":"Old","promptText":"Clean it","useSystemInstructions":false}
            """
        let prompt = try JSONDecoder().decode(CustomPrompt.self, from: Data(json.utf8))

        #expect(prompt.title == "Old")
        #expect(prompt.outputTemplate.isEmpty)
        #expect(prompt.styleExamples.isEmpty)
        #expect(prompt.finalPromptText == "Clean it")
    }

    @Test func roundTripsTemplateAndExamples() throws {
        let prompt = CustomPrompt(
            title: "Note",
            promptText: "Write a note",
            useSystemInstructions: false,
            outputTemplate: "HPI:\nPlan:",
            styleExamples: "HPI: 54M with 3d cough."
        )
        let decoded = try JSONDecoder().decode(CustomPrompt.self, from: JSONEncoder().encode(prompt))

        #expect(decoded == prompt)
    }

    @Test func omitsEmptyReferenceFieldsWhenEncoding() throws {
        let prompt = CustomPrompt(title: "Plain", promptText: "Clean it")
        let json = String(decoding: try JSONEncoder().encode(prompt), as: UTF8.self)

        #expect(!json.contains("outputTemplate"))
        #expect(!json.contains("styleExamples"))
    }

    @Test func appendsTemplateAndExamplesAfterInstructions() {
        let prompt = CustomPrompt(
            title: "Note",
            promptText: "INSTRUCTIONS",
            useSystemInstructions: false,
            outputTemplate: "  HPI:\nPlan:  \n",
            styleExamples: "EXAMPLE NOTE"
        )
        let text = prompt.finalPromptText

        #expect(text.hasPrefix("INSTRUCTIONS\n\n# Output Template"))
        #expect(text.contains("<OUTPUT_TEMPLATE>\nHPI:\nPlan:\n</OUTPUT_TEMPLATE>"))
        #expect(text.contains("<STYLE_EXAMPLES>\nEXAMPLE NOTE\n</STYLE_EXAMPLES>"))
        #expect(text.range(of: "<OUTPUT_TEMPLATE>")!.lowerBound < text.range(of: "<STYLE_EXAMPLES>")!.lowerBound)
    }

    @Test func leavesPromptUnchangedWithoutReferenceFields() {
        let prompt = CustomPrompt(title: "Plain", promptText: "INSTRUCTIONS", useSystemInstructions: false)

        #expect(prompt.finalPromptText == "INSTRUCTIONS")
    }

    @Test func clinicNoteTemplateCarriesItsOutputTemplate() throws {
        let prompt = try #require(
            PromptTemplates.seedPrompts.first { $0.id == PromptTemplates.clinicNotePromptId })

        #expect(!prompt.useSystemInstructions)
        #expect(prompt.outputTemplate.contains("Assessment and Plan:"))
        #expect(prompt.finalPromptText.contains("<OUTPUT_TEMPLATE>"))
    }
}

struct ModeContinuationCodingTests {
    private func decodeMode(_ extraFields: String = "") throws -> ModeConfig {
        let json = """
            {"id":"00000000-0000-0000-0000-0000000000BB","name":"Clinic","isAIEnhancementEnabled":true\(extraFields)}
            """
        return try JSONDecoder().decode(ModeConfig.self, from: Data(json.utf8))
    }

    @Test func defaultsToOffForModesSavedBeforeContinuation() throws {
        #expect(try decodeMode().continuation == .off)
    }

    @Test(arguments: [
        DictationContinuation.off, .timed(seconds: 30), .untilFinished,
    ])
    func roundTripsContinuation(_ continuation: DictationContinuation) throws {
        var mode = try decodeMode()
        mode.continuation = continuation
        let decoded = try JSONDecoder().decode(ModeConfig.self, from: JSONEncoder().encode(mode))

        #expect(decoded.continuation == continuation)
    }

    @Test func ignoresUnreadableContinuationValues() throws {
        #expect(try decodeMode(#","continuation":"sometimes""#).continuation == .off)
    }
}

struct EnhancementTimeoutTests {
    private func words(_ count: Int) -> String {
        Array(repeating: "word", count: count).joined(separator: " ")
    }

    @Test func keepsConfiguredTimeoutForShortDictation() {
        #expect(EnhancementRequestSettings.timeout(forInput: words(80)) == EnhancementRequestSettings.timeout)
    }

    @Test func growsWithLongDictation() {
        let base = EnhancementRequestSettings.timeout
        let longNote = EnhancementRequestSettings.timeout(forInput: words(600))

        #expect(longNote == base + 500 * 0.12)
    }

    @Test func isCappedForVeryLongDictation() {
        let cap = max(EnhancementRequestSettings.timeout, 180)

        #expect(EnhancementRequestSettings.timeout(forInput: words(10_000)) == cap)
    }
}

@MainActor
struct ModeDataLocalityTests {
    @Test(arguments: [
        "http://localhost:11434", "http://127.0.0.1:1234/v1", "http://[::1]:8080", "http://studio.local:1234",
    ])
    func treatsLoopbackAndLocalNetworkHostsAsLocal(_ url: String) {
        #expect(ModeDataLocality.isLocalURL(url))
    }

    @Test(arguments: ["https://api.openai.com/v1", "https://localhost.example.com", "not a url", ""])
    func treatsOtherHostsAsRemote(_ url: String) {
        #expect(!ModeDataLocality.isLocalURL(url))
    }

    @Test func classifiesBuiltInEnhancementProviders() {
        #expect(ModeDataLocality.isOnDevice(.localCLI, modelName: nil))
        #expect(ModeDataLocality.isOnDevice(.voiceRefine, modelName: nil))
        #expect(!ModeDataLocality.isOnDevice(.openAI, modelName: nil))
        #expect(!ModeDataLocality.isOnDevice(.anthropic, modelName: nil))
    }
}

@MainActor
struct DictationNoteSessionTests {
    private func mode(_ continuation: DictationContinuation) -> ModeConfig {
        var mode = ModeConfig(name: "Clinic", isAIEnhancementEnabled: true)
        mode.continuation = continuation
        return mode
    }

    private func part(_ text: String, duration: TimeInterval = 10) -> DictationNoteSession.Part {
        DictationNoteSession.Part(id: UUID(), text: text, duration: duration)
    }

    @Test func combinesPartsInOrderAndResets() throws {
        let session = DictationNoteSession()
        session.begin(mode: mode(.untilFinished), contextSnapshot: nil)
        session.append(part("HPI dictated first.", duration: 12), targetBundleIdentifier: "com.example.ehr")
        session.append(part("Plan dictated second.", duration: 8), targetBundleIdentifier: nil)

        let snapshot = try #require(session.takeSnapshot())

        #expect(snapshot.combinedText == "HPI dictated first.\n\nPlan dictated second.")
        #expect(snapshot.totalDuration == 20)
        #expect(snapshot.targetBundleIdentifier == "com.example.ehr")
        #expect(!session.isActive)
        #expect(session.parts.isEmpty)
    }

    @Test func hasNothingToDeliverWithoutParts() {
        let session = DictationNoteSession()
        session.begin(mode: mode(.timed(seconds: 10)), contextSnapshot: nil)

        #expect(session.takeSnapshot() == nil)
        #expect(!session.isActive)
    }

    @Test func waitsForClickWhenUntilFinished() {
        let session = DictationNoteSession()
        session.begin(mode: mode(.untilFinished), contextSnapshot: nil)
        session.scheduleFinish {}

        #expect(session.finishDeadline == nil)
    }

    @Test func finishesWhenTimedWaitRunsOut() async throws {
        let session = DictationNoteSession()
        session.begin(mode: mode(.timed(seconds: 1)), contextSnapshot: nil)
        var didFinish = false
        session.scheduleFinish { didFinish = true }

        #expect(session.finishDeadline != nil)
        try await Task.sleep(for: .milliseconds(1_400))
        #expect(didFinish)
    }

    @Test func newPartStopsTheCountdown() async throws {
        let session = DictationNoteSession()
        session.begin(mode: mode(.timed(seconds: 1)), contextSnapshot: nil)
        var didFinish = false
        session.scheduleFinish { didFinish = true }
        session.cancelCountdown()

        try await Task.sleep(for: .milliseconds(1_400))
        #expect(!didFinish)
        #expect(session.finishDeadline == nil)
    }
}
