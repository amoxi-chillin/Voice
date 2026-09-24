import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case shortcuts
    case recorder
    case audio
    case pasting
    case data
    case license

    var id: String { rawValue }

    /// Maps the destinations that used to be main-window sidebar screens.
    init?(legacyDestination: String) {
        switch legacyDestination {
        case "Settings": self = .general
        case "Audio": self = .audio
        case "VoiceInk Pro": self = .license
        default: return nil
        }
    }

    static var visibleTabs: [SettingsTab] {
        #if LOCAL_BUILD
            allCases.filter { $0 != .license }
        #else
            allCases
        #endif
    }
}

final class SettingsNavigation: ObservableObject {
    static let shared = SettingsNavigation()

    @Published var selectedTab: SettingsTab = .general

    private init() {}
}

/// Opens the Settings window from contexts with no view hierarchy, such as a notification action.
enum SettingsWindowPresenter {
    static func open(_ tab: SettingsTab? = nil) {
        if let tab, SettingsTab.visibleTabs.contains(tab) {
            SettingsNavigation.shared.selectedTab = tab
        }
        NotificationCenter.default.post(name: .showSettingsRequested, object: nil)
    }
}

/// Lives in an always-present view so `openSettings` is reachable while the main window is closed.
struct SettingsRequestBridge: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onReceive(NotificationCenter.default.publisher(for: .showSettingsRequested)) { _ in
                AppPresentationPolicy.activateForUserFacingWindow()
                openSettings()
            }
    }
}

struct SettingsWindowView: View {
    @ObservedObject private var navigation = SettingsNavigation.shared

    var body: some View {
        TabView(selection: $navigation.selectedTab) {
            Tab("General", systemImage: "gearshape", value: SettingsTab.general) {
                GeneralSettingsView()
            }

            Tab("Shortcuts", systemImage: "keyboard", value: SettingsTab.shortcuts) {
                ShortcutsSettingsView()
            }

            Tab("Recorder", systemImage: "waveform", value: SettingsTab.recorder) {
                RecorderSettingsView()
            }

            Tab("Audio", systemImage: "speaker.wave.2", value: SettingsTab.audio) {
                AudioSettingsView()
            }

            Tab("Pasting", systemImage: "clipboard", value: SettingsTab.pasting) {
                PastingSettingsView()
            }

            Tab("Data", systemImage: "folder", value: SettingsTab.data) {
                DataSettingsView()
            }

            #if !LOCAL_BUILD
                Tab("License", systemImage: "key", value: SettingsTab.license) {
                    LicenseSettingsView()
                }
            #endif
        }
        .frame(width: 720, height: 620)
    }
}
