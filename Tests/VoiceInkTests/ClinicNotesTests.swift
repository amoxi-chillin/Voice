import Foundation
import Testing
@testable import VoiceInk

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
