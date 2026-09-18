import Carbon.HIToolbox
import SwiftUI

struct ShortcutsSettingsView: View {
    @EnvironmentObject private var recordingShortcutManager: RecordingShortcutManager
    @State private var cancelRecordingShortcutRecorderResetID = 0

    private static let defaultCancelRecordingShortcut = Shortcut.key(
        keyCode: UInt16(kVK_Escape),
        modifierFlags: []
    )

    var body: some View {
        Form {
            Section {
                LabeledContent("Primary Shortcut") {
                    HStack(spacing: 8) {
                        shortcutModePicker(binding: $recordingShortcutManager.primaryRecordingShortcutMode)
                        ShortcutRecorder(action: .primaryRecording) {
                            recordingShortcutManager.primaryRecordingShortcut = .custom
                            recordingShortcutManager.updateShortcutStatus()
                        }
                    }
                }

                if recordingShortcutManager.secondaryRecordingShortcut != .none {
                    LabeledContent("Secondary Shortcut") {
                        HStack(spacing: 8) {
                            shortcutModePicker(binding: $recordingShortcutManager.secondaryRecordingShortcutMode)
                            ShortcutRecorder(action: .secondaryRecording) {
                                recordingShortcutManager.secondaryRecordingShortcut = .custom
                                recordingShortcutManager.updateShortcutStatus()
                            }
                            Button("Remove Secondary Shortcut", systemImage: "minus.circle") {
                                withAnimation { recordingShortcutManager.secondaryRecordingShortcut = .none }
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .help("Remove Secondary Shortcut")
                        }
                    }
                } else {
                    LabeledContent("Secondary Shortcut") {
                        Button("Add…") {
                            withAnimation { recordingShortcutManager.secondaryRecordingShortcut = .custom }
                        }
                    }
                }

                LabeledContent {
                    HStack(spacing: 8) {
                        ShortcutRecorder(
                            action: .cancelRecorder,
                            defaultShortcut: Self.defaultCancelRecordingShortcut
                        )
                        .id(cancelRecordingShortcutRecorderResetID)

                        Button("Reset to Default", systemImage: "arrow.counterclockwise") {
                            RecorderPanelShortcutManager.resetEscapeConfirmationHint()
                            ShortcutStore.setShortcut(nil, for: .cancelRecorder)
                            cancelRecordingShortcutRecorderResetID += 1
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Reset to Default")
                    }
                } label: {
                    Text("Cancel Recording")
                    Text("By default, press Escape twice to discard the current recording.")
                }
            } header: {
                Text("Dictation")
            } footer: {
                Text(
                    "Push to Talk records while the shortcut is held. Toggle starts and stops with a press. Hybrid does both. Shortcuts can use keys, modifiers or mouse buttons."
                )
            }

            Section("Transcriptions") {
                shortcutRow("Paste Last Transcription", subtitle: "Original text", action: .pasteLastTranscription)
                shortcutRow("Paste Last Enhanced Transcription", action: .pasteLastEnhancement)
                shortcutRow("Retry Last Transcription", action: .retryLastTranscription)
                shortcutRow("Quick History", action: .openQuickHistory)
                shortcutRow("Add Selection to Dictionary", action: .quickAddToDictionary)
            }
        }
        .formStyle(.grouped)
    }

    private func shortcutRow(
        _ title: LocalizedStringKey,
        subtitle: LocalizedStringKey? = nil,
        action: ShortcutAction
    ) -> some View {
        LabeledContent {
            ShortcutRecorder(action: action) {
                recordingShortcutManager.updateShortcutStatus()
            }
        } label: {
            Text(title)
            if let subtitle {
                Text(subtitle)
            }
        }
    }

    private func shortcutModePicker(binding: Binding<RecordingShortcutManager.Mode>) -> some View {
        Picker("Mode", selection: binding) {
            ForEach(RecordingShortcutManager.Mode.allCases, id: \.self) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
        .labelsHidden()
        .fixedSize()
    }
}
