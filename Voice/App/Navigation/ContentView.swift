import OSLog
import SwiftUI

enum ViewType: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard"
    case modes = "Modes"
    case transcribeAudio = "Transcribe Audio"
    case history = "History"
    case dictionary = "Dictionary"
    case models = "AI Models"

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .dashboard: return "Dashboard"
        case .modes: return "Modes"
        case .transcribeAudio: return "Transcribe"
        case .history: return "History"
        case .dictionary: return "Dictionary"
        case .models: return "Models"
        }
    }

    var systemImage: String {
        switch self {
        case .dashboard: return "gauge.with.dots.needle.33percent"
        case .modes: return "square.stack.3d.up"
        case .transcribeAudio: return "waveform"
        case .history: return "clock"
        case .dictionary: return "character.book.closed"
        case .models: return "cpu"
        }
    }
}

final class MainWindowNavigation: ObservableObject {
    static let shared = MainWindowNavigation()

    @Published var selectedView: ViewType = .dashboard

    private init() {}

    /// Routes legacy string destinations; screens that moved to the Settings window open it instead.
    func navigate(to destination: String) {
        if let viewType = ViewType(rawValue: destination) {
            navigate(to: viewType)
        } else if let tab = SettingsTab(legacyDestination: destination) {
            SettingsWindowPresenter.open(tab)
        }
    }

    func navigate(to destination: ViewType) {
        selectedView = destination
    }
}

struct ContentView: View {
    private let logger = Logger(subsystem: "com.amoxichillin.voice", category: "ContentView")
    @EnvironmentObject private var navigation: MainWindowNavigation

    var body: some View {
        NavigationSplitView {
            AppSidebar(selection: $navigation.selectedView)
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } detail: {
            detailView(for: navigation.selectedView)
                .navigationTitle(navigation.selectedView.title)
        }
        .frame(minWidth: AppWindowLayout.minimumWidth, minHeight: AppWindowLayout.minimumHeight)
        .onAppear {
            logger.notice("ContentView appeared")
        }
        .onDisappear {
            logger.notice("ContentView disappeared")
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToDestination)) { notification in
            if let destination = notification.userInfo?["destination"] as? String {
                logger.notice("navigateToDestination received: \(destination, privacy: .public)")
                navigation.navigate(to: destination)
            }
        }
    }

    @ViewBuilder
    private func detailView(for viewType: ViewType) -> some View {
        switch viewType {
        case .dashboard:
            DashboardView()
        case .models:
            ModelManagementView()
        case .transcribeAudio:
            AudioTranscribeView()
        case .history:
            HistoryView()
        case .dictionary:
            DictionarySettingsView()
        case .modes:
            ModeView()
        }
    }
}
