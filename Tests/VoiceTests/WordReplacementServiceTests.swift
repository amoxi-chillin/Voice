import SwiftData
import Testing
@testable import Voice

@MainActor
struct WordReplacementServiceTests {
    private func apply(_ text: String, replacing original: String, with replacement: String) throws -> String {
        let container = try ModelContainer(
            for: WordReplacement.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = container.mainContext
        context.insert(WordReplacement(originalText: original, replacementText: replacement))
        try context.save()
        return WordReplacementService.shared.applyReplacements(to: text, using: context)
    }

    @Test func insertsDollarAmountsLiterally() throws {
        let result = try apply("Copay is five dollars today.", replacing: "five dollars", with: "$5")

        #expect(result == "Copay is $5 today.")
    }

    @Test func insertsBackslashesLiterally() throws {
        let result = try apply("Save it to the share path.", replacing: "share path", with: #"\\server\share"#)

        #expect(result == #"Save it to the \\server\share."#)
    }
}
