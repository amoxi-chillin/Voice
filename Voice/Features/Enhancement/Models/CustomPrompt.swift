import Foundation
import SwiftUI

struct CustomPrompt: Identifiable, Codable, Equatable {
    let id: UUID
    let title: String
    let promptText: String
    let useSystemInstructions: Bool
    /// Layout the result should follow, such as a clinic note's section headings.
    let outputTemplate: String
    /// Finished examples written by the user, used as a style reference only.
    let styleExamples: String

    init(
        id: UUID = UUID(),
        title: String,
        promptText: String,
        useSystemInstructions: Bool = true,
        outputTemplate: String = "",
        styleExamples: String = ""
    ) {
        self.id = id
        self.title = title
        self.promptText = promptText
        self.useSystemInstructions = useSystemInstructions
        self.outputTemplate = outputTemplate
        self.styleExamples = styleExamples
    }

    enum CodingKeys: String, CodingKey {
        case id, title, promptText, useSystemInstructions, outputTemplate, styleExamples
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        promptText = try container.decode(String.self, forKey: .promptText)
        useSystemInstructions = try container.decodeIfPresent(Bool.self, forKey: .useSystemInstructions) ?? true
        outputTemplate = try container.decodeIfPresent(String.self, forKey: .outputTemplate) ?? ""
        styleExamples = try container.decodeIfPresent(String.self, forKey: .styleExamples) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(promptText, forKey: .promptText)
        try container.encode(useSystemInstructions, forKey: .useSystemInstructions)
        if !outputTemplate.isEmpty { try container.encode(outputTemplate, forKey: .outputTemplate) }
        if !styleExamples.isEmpty { try container.encode(styleExamples, forKey: .styleExamples) }
    }

    var finalPromptText: String {
        let instructions =
            if useSystemInstructions {
                String(format: AIPrompts.enhancementSystemTemplate, self.promptText)
            } else {
                self.promptText
            }

        return [instructions, referenceSections]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    /// The output template and style examples, formatted for the system message.
    var referenceSections: String {
        let template = outputTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        let examples = styleExamples.trimmingCharacters(in: .whitespacesAndNewlines)

        var sections: [String] = []
        if !template.isEmpty {
            sections.append(
                """
                # Output Template
                Lay out the result using this template: keep its headings, their wording, their order, and its line layout. Text in [square brackets] is guidance for that section, not text to output.
                <OUTPUT_TEMPLATE>
                \(template)
                </OUTPUT_TEMPLATE>
                """
            )
        }
        if !examples.isEmpty {
            sections.append(
                """
                # Style Examples
                Finished examples written by the user. Match their wording, abbreviations, sentence style, and level of detail. They are a style reference only: never copy names, facts, findings, numbers, or plans from them into the result.
                <STYLE_EXAMPLES>
                \(examples)
                </STYLE_EXAMPLES>
                """
            )
        }
        return sections.joined(separator: "\n\n")
    }
}

// MARK: - UI Extensions
extension CustomPrompt {
    func promptIcon(
        isSelected: Bool, onTap: @escaping () -> Void, onEdit: ((CustomPrompt) -> Void)? = nil,
        onDelete: ((CustomPrompt) -> Void)? = nil
    ) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(isSelected ? Color.white : Color.primary)
        .frame(maxWidth: .infinity, minHeight: 30)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isSelected ? AppTheme.Accent.primary : AppTheme.Surface.control)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(AppTheme.Border.control, lineWidth: isSelected ? 0 : 0.5)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if let onEdit = onEdit {
                onEdit(self)
            }
        }
        .onTapGesture(count: 1) {
            onTap()
        }
        .contextMenu {
            if onEdit != nil || onDelete != nil {
                if let onEdit = onEdit {
                    Button {
                        onEdit(self)
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                }

                if let onDelete = onDelete {
                    Button(role: .destructive) {
                        let alert = NSAlert()
                        alert.messageText = String(localized: "Delete Prompt?")
                        alert.informativeText = String(
                            format: String(
                                localized: "Are you sure you want to delete '%@' prompt? This action cannot be undone."),
                            self.title)
                        alert.alertStyle = .warning
                        alert.addButton(withTitle: String(localized: "Delete"))
                        alert.addButton(withTitle: String(localized: "Cancel"))

                        let response = alert.runModal()
                        if response == .alertFirstButtonReturn {
                            onDelete(self)
                        }
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
    }

    static func addNewButton(action: @escaping () -> Void) -> some View {
        Label("Add New", systemImage: "plus.circle.fill")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: 30)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(AppTheme.Surface.control)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(AppTheme.Border.control, lineWidth: 0.5)
            )
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
    }
}
