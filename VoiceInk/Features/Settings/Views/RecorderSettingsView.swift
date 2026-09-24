import SwiftUI

struct RecorderSettingsView: View {
    @EnvironmentObject private var recorderUIManager: RecorderUIManager
    @AppStorage(RecorderDisplaySettingsKeys.showLiveTranscript) private var showLiveTranscript = true

    var body: some View {
        Form {
            Section("Style") {
                HStack(spacing: 28) {
                    ForEach(RecorderPanelStyle.allCases) { style in
                        RecorderStyleOption(
                            style: style,
                            isSelected: recorderUIManager.recorderPanelStyle == style
                        ) {
                            recorderUIManager.recorderPanelStyle = style
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }

            Section {
                Toggle(isOn: $showLiveTranscript) {
                    Text("Live Text Display")
                    Text("Show words in the recorder as you speak with realtime models.")
                }
            }

            Section("Sounds") {
                CustomSoundSettingsView()
            }
        }
        .formStyle(.grouped)
    }
}

/// Thumbnail choice in the style of System Settings ▸ Appearance.
private struct RecorderStyleOption: View {
    let style: RecorderPanelStyle
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                thumbnail
                    .frame(width: 150, height: 84)
                    .clipShape(.rect(cornerRadius: 10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator),
                                lineWidth: isSelected ? 3 : 1)
                    }

                Text(style.displayName)
                    .font(.callout)
                    .fontWeight(isSelected ? .semibold : .regular)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(style.displayName)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private var thumbnail: some View {
        ZStack {
            Rectangle().fill(.quaternary)

            switch style {
            case .notch:
                UnevenRoundedRectangle(bottomLeadingRadius: 6, bottomTrailingRadius: 6)
                    .fill(.black)
                    .frame(width: 70, height: 12)
                    .frame(maxHeight: .infinity, alignment: .top)
            case .mini:
                Capsule()
                    .fill(.regularMaterial)
                    .frame(width: 56, height: 14)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 10)
            }
        }
    }
}
