import Foundation

struct TranscriptionOutputFilter {
    private static let hallucinationPatterns = [
        #"\[.*?\]"#,  // []
        #"\([^()\d]*\)"#,  // () without digits, so "(555) 123-4567" survives
        #"\{.*?\}"#,  // {}
    ]

    static func filter(_ text: String, fillerWords: [String] = FillerWordManager.shared.fillerWords) -> String {
        var filteredText = text

        // Remove <TAG>...</TAG> blocks
        let tagBlockPattern = #"<([A-Za-z][A-Za-z0-9:_-]*)[^>]*>[\s\S]*?</\1>"#
        if let regex = try? NSRegularExpression(pattern: tagBlockPattern) {
            let range = NSRange(filteredText.startIndex..., in: filteredText)
            filteredText = regex.stringByReplacingMatches(in: filteredText, options: [], range: range, withTemplate: "")
        }

        // Remove bracketed hallucinations
        for pattern in hallucinationPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(filteredText.startIndex..., in: filteredText)
                filteredText = regex.stringByReplacingMatches(
                    in: filteredText, options: [], range: range, withTemplate: "")
            }
        }

        // Remove configured filler words. An empty list is naturally a no-op.
        for fillerWord in fillerWords {
            guard let regex = fillerWordRegex(for: fillerWord) else { continue }
            let range = NSRange(filteredText.startIndex..., in: filteredText)
            filteredText = regex.stringByReplacingMatches(
                in: filteredText, options: [], range: range, withTemplate: "")
        }

        // Clean whitespace
        filteredText = filteredText.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        filteredText = filteredText.trimmingCharacters(in: .whitespacesAndNewlines)

        return filteredText
    }

    /// Matches a filler word in lowercase or sentence case only, so abbreviations such as
    /// "MM" or "MH" survive, and never right after a number, so units such as "5 mm" survive.
    private static func fillerWordRegex(for fillerWord: String) -> NSRegularExpression? {
        let word = fillerWord.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !word.isEmpty else { return nil }

        let variants = Set([word, word.prefix(1).uppercased() + word.dropFirst()])
            .map(NSRegularExpression.escapedPattern(for:))
            .sorted()
            .joined(separator: "|")
        return try? NSRegularExpression(pattern: #"(?<!\d)(?<!\d\s)\b(?:"# + variants + #")\b[,.]?"#)
    }
}
