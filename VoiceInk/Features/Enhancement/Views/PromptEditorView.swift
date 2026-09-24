import SwiftUI

struct PromptEditorView: View {
    enum Mode {
        case add
        case edit(CustomPrompt)

        static func == (lhs: Mode, rhs: Mode) -> Bool {
            switch (lhs, rhs) {
            case (.add, .add):
                return true
            case (.edit(let prompt1), .edit(let prompt2)):
                return prompt1.id == prompt2.id
            default:
                return false
            }
        }
    }

    let mode: Mode
    @EnvironmentObject private var enhancementService: AIEnhancementService
    let onDismiss: () -> Void
    let onSave: (CustomPrompt) -> Void
    let onDelete: ((CustomPrompt) -> Void)?
    @State private var title: String
    @State private var promptText: String
    @State private var useSystemInstructions: Bool
    @State private var outputTemplate: String
    @State private var styleExamples: String
    @State private var isReferenceExpanded: Bool
    @State private var showDeleteConfirmation = false

    private var saveButtonTitle: LocalizedStringKey {
        mode == .add ? "Create & Select" : "Save & Select"
    }

    private var editingPrompt: CustomPrompt? {
        if case .edit(let prompt) = mode {
            return prompt
        }
        return nil
    }

    private var canDeletePrompt: Bool {
        editingPrompt != nil && onDelete != nil
    }

    private var isSaveDisabled: Bool {
        return title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init(
        mode: Mode,
        onDismiss: @escaping () -> Void,
        onSave: @escaping (CustomPrompt) -> Void,
        onDelete: ((CustomPrompt) -> Void)? = nil
    ) {
        self.mode = mode
        self.onDismiss = onDismiss
        self.onSave = onSave
        self.onDelete = onDelete
        switch mode {
        case .add:
            _title = State(initialValue: "")
            _promptText = State(initialValue: "")
            _useSystemInstructions = State(initialValue: true)
            _outputTemplate = State(initialValue: "")
            _styleExamples = State(initialValue: "")
            _isReferenceExpanded = State(initialValue: false)
        case .edit(let prompt):
            _title = State(initialValue: prompt.title)
            _promptText = State(initialValue: prompt.promptText)
            _useSystemInstructions = State(initialValue: prompt.useSystemInstructions)
            _outputTemplate = State(initialValue: prompt.outputTemplate)
            _styleExamples = State(initialValue: prompt.styleExamples)
            _isReferenceExpanded = State(
                initialValue: !prompt.outputTemplate.isEmpty || !prompt.styleExamples.isEmpty)
        }
    }

    private func dismissPanel() {
        onDismiss()
    }

    var body: some View {
        QuickPanelScaffold {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if case .add = mode {
                        templateMenu
                    }

                    instructionsEditor
                    referenceSection
                    systemTemplateToggle
                }
                .padding(.horizontal, 20)
                .padding(.top, 76)
                .padding(.bottom, 72)
            }
        } header: {
            header
        } footer: {
            footer
        }
        .confirmationDialog(
            "Delete Prompt?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                deletePrompt()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                String(
                    format: String(localized: "Are you sure you want to delete '%@'? This action cannot be undone."),
                    title))
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                dismissPanel()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(width: 28, height: 28)
                    .background(AppTheme.Surface.card)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
            .help("Back")

            TextField("Prompt name", text: $title)
                .textFieldStyle(.plain)
                .font(.system(size: 16, weight: .semibold))

            Spacer()
        }
        .padding(.horizontal, 20)
        .frame(height: QuickPanelMetrics.headerHeight)
    }

    private var systemTemplateToggle: some View {
        HStack(spacing: 12) {
            Toggle(isOn: $useSystemInstructions) {
                HStack(spacing: 4) {
                    Text("Use System Template")
                    InfoTip(
                        "If enabled, your instructions are combined with a general-purpose template to improve transcription quality.\n\nDisable for full control over the AI's system prompt (for advanced users)."
                    )
                }
            }
            .toggleStyle(.switch)

            Spacer(minLength: 12)
        }
    }

    private var templateMenu: some View {
        Menu {
            ForEach(PromptTemplates.all) { template in
                Button {
                    title = template.title
                    promptText = template.promptText
                    useSystemInstructions = template.useSystemInstructions
                    outputTemplate = template.outputTemplate
                    styleExamples = template.styleExamples
                    isReferenceExpanded = !template.outputTemplate.isEmpty || !template.styleExamples.isEmpty
                } label: {
                    Text(template.title)
                }
            }
        } label: {
            Label("Template", systemImage: "sparkles")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
        .help("Start with a template")
    }

    private var instructionsEditor: some View {
        PromptTextEditor(
            text: $promptText,
            placeholder: "Write prompt instructions",
            height: isReferenceExpanded ? 300 : 440
        )
    }

    private var referenceSection: some View {
        DisclosureGroup(isExpanded: $isReferenceExpanded) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 4) {
                        Text("Output Template")
                            .font(.system(size: 13, weight: .medium))
                        InfoTip(
                            "The layout the result should follow, such as your note's section headings in order. Text in [square brackets] is treated as guidance for that section."
                        )
                    }
                    PromptTextEditor(
                        text: $outputTemplate,
                        placeholder: "Chief Complaint:\nHPI:\nExam:\nAssessment and Plan:",
                        height: 150
                    )
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 4) {
                        Text("Style Examples")
                            .font(.system(size: 13, weight: .medium))
                        InfoTip(
                            "Paste one to three finished examples written the way you want results to read. They are sent with every request as a style reference, so remove names, dates of birth, and other identifiers first."
                        )
                    }
                    PromptTextEditor(
                        text: $styleExamples,
                        placeholder: "Paste de-identified examples of finished notes",
                        height: 220
                    )
                }
            }
            .padding(.top, 10)
        } label: {
            Text("Output Template & Style Examples")
                .font(.system(size: 13, weight: .medium))
        }
    }

    private var footer: some View {
        HStack {
            if canDeletePrompt {
                AppActionButton("Delete", kind: .destructive, minWidth: 90) {
                    showDeleteConfirmation = true
                }
            } else {
                AppActionButton("Cancel") {
                    dismissPanel()
                }
                .keyboardShortcut(.escape, modifiers: [])
            }

            Spacer()

            AppActionButton(saveButtonTitle, kind: .primary, minWidth: 108) {
                if let savedPrompt = save() {
                    onSave(savedPrompt)
                }
                dismissPanel()
            }
            .disabled(isSaveDisabled)
            .keyboardShortcut(.return, modifiers: .command)
            .help("Save this prompt and select it.")
        }
        .padding(.horizontal, 20)
        .frame(height: QuickPanelMetrics.footerHeight)
    }

    private func deletePrompt() {
        guard let prompt = editingPrompt, canDeletePrompt else { return }
        onDelete?(prompt)
        dismissPanel()
    }

    private func save() -> CustomPrompt? {
        switch mode {
        case .add:
            return enhancementService.addPrompt(
                title: title,
                promptText: promptText,
                useSystemInstructions: useSystemInstructions,
                outputTemplate: outputTemplate,
                styleExamples: styleExamples
            )
        case .edit(let prompt):
            let updatedPrompt = CustomPrompt(
                id: prompt.id,
                title: title,
                promptText: promptText,
                useSystemInstructions: useSystemInstructions,
                outputTemplate: outputTemplate,
                styleExamples: styleExamples
            )
            enhancementService.updatePrompt(updatedPrompt)
            return updatedPrompt
        }
    }
}

private struct PromptTextEditor: View {
    @Binding var text: String
    let placeholder: LocalizedStringKey
    let height: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .frame(height: height)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(AppCardBackground(cornerRadius: 8))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            if text.isEmpty {
                Text(placeholder)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                    .allowsHitTesting(false)
            }
        }
    }
}
