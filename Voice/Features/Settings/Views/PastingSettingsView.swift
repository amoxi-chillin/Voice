import SwiftUI

struct PastingSettingsView: View {
    @AppStorage(PasteMethod.userDefaultsKey) private var pasteMethodRawValue = PasteMethod.standard.rawValue
    @AppStorage("AppendTrailingSpace") private var appendTrailingSpace = true
    @AppStorage("restoreClipboardAfterPaste") private var restoreClipboardAfterPaste = true
    @AppStorage("clipboardRestoreDelay") private var clipboardRestoreDelay = 2.0

    var body: some View {
        Form {
            Section("Paste") {
                Picker(selection: $pasteMethodRawValue) {
                    ForEach(PasteMethod.allCases) { method in
                        Text(method.displayName).tag(method.rawValue)
                    }
                } label: {
                    Text("Paste Method")
                    Text("Use AppleScript if a custom keyboard layout doesn't paste correctly.")
                }
                .onChange(of: pasteMethodRawValue) { _, newValue in
                    guard let method = PasteMethod(rawValue: newValue) else {
                        pasteMethodRawValue = PasteMethod.standard.rawValue
                        return
                    }
                    PasteMethod.setCurrent(method)
                }

                Toggle("Add Space After Paste", isOn: $appendTrailingSpace)
            }

            Section("Clipboard") {
                Toggle(isOn: $restoreClipboardAfterPaste) {
                    Text("Keep Clipboard Content")
                    Text(
                        "Restore what you had copied after pasting. When off, the transcription stays on the clipboard."
                    )
                }

                Picker("Restore Delay", selection: $clipboardRestoreDelay) {
                    Text("250 ms").tag(0.25)
                    Text("500 ms").tag(0.5)
                    Text("1 second").tag(1.0)
                    Text("2 seconds").tag(2.0)
                    Text("3 seconds").tag(3.0)
                    Text("4 seconds").tag(4.0)
                    Text("5 seconds").tag(5.0)
                }
                .disabled(!restoreClipboardAfterPaste)
            }
        }
        .formStyle(.grouped)
    }
}
