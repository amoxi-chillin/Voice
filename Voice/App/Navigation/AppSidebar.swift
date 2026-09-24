import SwiftUI

struct AppSidebar: View {
    @Binding var selection: ViewType

    var body: some View {
        List(selection: selectionBinding) {
            ForEach(ViewType.allCases) { viewType in
                Label(viewType.title, systemImage: viewType.systemImage)
                    .tag(viewType)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SidebarStatusRow()
        }
    }

    /// `List` clears its selection on an empty click; the main window always shows a screen.
    private var selectionBinding: Binding<ViewType?> {
        Binding(
            get: { selection },
            set: { newValue in
                if let newValue {
                    selection = newValue
                }
            }
        )
    }
}

private struct SidebarStatusRow: View {
    @EnvironmentObject private var engine: VoiceEngine
    @EnvironmentObject private var recordingShortcutManager: RecordingShortcutManager
    @State private var primaryShortcut = ShortcutStore.shortcut(for: .primaryRecording)

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: statusSymbol)
                .font(.title)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(statusStyle)
                .contentTransition(.symbolEffect(.replace))

            VStack(alignment: .leading, spacing: 1) {
                Text(statusTitle)
                    .font(.callout.weight(.semibold))

                if let shortcutHint {
                    Text(shortcutHint)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
        .onReceive(NotificationCenter.default.publisher(for: ShortcutStore.shortcutDidChange)) { _ in
            primaryShortcut = ShortcutStore.shortcut(for: .primaryRecording)
        }
    }

    private var statusTitle: LocalizedStringKey {
        switch engine.recordingState {
        case .idle: return "Ready to dictate"
        case .starting: return "Starting…"
        case .recording: return "Recording…"
        case .transcribing: return "Transcribing…"
        case .enhancing: return "Enhancing…"
        case .busy: return "Working…"
        }
    }

    private var statusSymbol: String {
        switch engine.recordingState {
        case .idle: return "mic.circle.fill"
        case .recording: return "record.circle.fill"
        case .starting, .transcribing, .enhancing, .busy: return "ellipsis.circle.fill"
        }
    }

    private var statusStyle: AnyShapeStyle {
        engine.recordingState == .recording ? AnyShapeStyle(.red) : AnyShapeStyle(.tint)
    }

    private var shortcutHint: String? {
        guard let primaryShortcut else {
            return String(localized: "No dictation shortcut set")
        }

        let shortcut = primaryShortcut.displayString
        switch recordingShortcutManager.primaryRecordingShortcutMode {
        case .pushToTalk:
            return String(format: String(localized: "Hold %@ to talk"), shortcut)
        case .toggle:
            return String(format: String(localized: "Press %@ to talk"), shortcut)
        case .hybrid:
            return String(format: String(localized: "Press or hold %@ to talk"), shortcut)
        }
    }
}
