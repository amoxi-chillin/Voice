import Testing
@testable import Voice

struct TranscriptionOutputFilterTests {
    private func filter(_ text: String) -> String {
        TranscriptionOutputFilter.filter(text, fillerWords: FillerWordManager.defaultFillerWords)
    }

    @Test(arguments: [
        ("Um, the patient is, uh, doing well.", "the patient is, doing well."),
        ("Hmm. Let me think. Mm, yes.", "Let me think. yes."),
        ("So umm we will follow up", "So we will follow up"),
    ])
    func removesSpokenFillers(_ input: String, _ expected: String) {
        #expect(filter(input) == expected)
    }

    @Test(arguments: [
        "There is a 5 mm nodule in the right upper lobe.",
        "BP 120/80 mm Hg.",
        "Lesion measures 3.2 mm, stable.",
        "History of MM, now in remission.",
        "Referred to MH services.",
    ])
    func keepsUnitsAndAbbreviations(_ input: String) {
        #expect(filter(input) == input)
    }

    @Test func keepsParenthesesThatContainNumbers() {
        #expect(filter("Call (555) 123-4567 today.") == "Call (555) 123-4567 today.")
    }

    @Test func removesASRSoundMarkers() {
        #expect(filter("[BLANK_AUDIO] Patient reports (coughing) chest pain.") == "Patient reports chest pain.")
    }
}
