import SwiftUI

struct GeneralSettingsView: View {
    @EnvironmentObject private var updaterViewModel: UpdaterViewModel
    @EnvironmentObject private var menuBarManager: MenuBarManager
    @EnvironmentObject private var recorderUIManager: RecorderUIManager
    @ObservedObject private var launchAtLoginManager = LaunchAtLoginManager.shared
    @AppStorage(OnboardingSettings.completedV2Key) private var hasCompletedOnboardingV2 = true
    @AppStorage(AppAppearancePreference.userDefaultsKey) private var appAppearancePreference = AppAppearancePreference
        .system
    @AppStorage(AppLanguagePreference.userDefaultsKey) private var appLanguagePreference = AppLanguagePreference
        .systemValue
    @AppStorage(RecorderDisplaySettingsKeys.showLiveTranscript) private var showLiveTranscript = true
    @State private var showResetOnboardingAlert = false
    @State private var showLanguageRestartAlert = false

    private let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""

    var body: some View {
        Form {
            Section("Interface") {
                Picker("Appearance", selection: $appAppearancePreference) {
                    ForEach(AppAppearancePreference.allCases) { preference in
                        Text(preference.displayName).tag(preference)
                    }
                }
                .onChange(of: appAppearancePreference) { _, newValue in
                    newValue.apply()
                }

                Picker("Language", selection: $appLanguagePreference) {
                    ForEach(AppLanguagePreference.availableOptions) { option in
                        Text(option.displayName).tag(option.id)
                    }
                }
                .onChange(of: appLanguagePreference) { oldValue, newValue in
                    guard oldValue != newValue else { return }
                    let normalizedValue = AppLanguagePreference.normalizedRawValue(newValue)
                    if normalizedValue != newValue {
                        appLanguagePreference = normalizedValue
                        return
                    }
                    AppLanguagePreference.apply(rawValue: normalizedValue)
                    showLanguageRestartAlert = true
                }

                Picker("Recorder Style", selection: $recorderUIManager.recorderPanelStyle) {
                    ForEach(RecorderPanelStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .pickerStyle(.segmented)

                Toggle(isOn: $showLiveTranscript) {
                    Text("Live Text Display")
                    Text("Show words in the recorder as you speak with realtime models.")
                }
            }

            Section("Startup") {
                Toggle(
                    "Launch at Login",
                    isOn: Binding(
                        get: { launchAtLoginManager.isEnabled },
                        set: { launchAtLoginManager.setEnabled($0) }
                    )
                )
                .disabled(launchAtLoginManager.isUpdating)

                Toggle(isOn: $menuBarManager.isMenuBarOnly) {
                    Text("Hide Dock Icon")
                    Text("Stays available from the menu bar.")
                }
            }

            if UpdaterViewModel.isUpdateFeedConfigured {
                Section("Updates") {
                    Toggle(
                        "Automatically Check for Updates",
                        isOn: Binding(
                            get: { updaterViewModel.checksForUpdatesWhenDashboardAppears },
                            set: { updaterViewModel.setChecksForUpdatesWhenDashboardAppears($0) }
                        ))

                    LabeledContent(String(format: String(localized: "Version %@"), appVersion)) {
                        Button("Check Now") {
                            updaterViewModel.checkForUpdates()
                        }
                        .disabled(!updaterViewModel.canCheckForUpdates)
                    }
                }
            } else {
                Section {
                    LabeledContent("Version", value: appVersion)
                }
            }

            Section {
                LabeledContent {
                    Button("Reset…") {
                        showResetOnboardingAlert = true
                    }
                } label: {
                    Text("Onboarding")
                    Text("Run the first-launch setup again.")
                }
            }
        }
        .formStyle(.grouped)
        .alert("Reset Onboarding", isPresented: $showResetOnboardingAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
                DispatchQueue.main.async {
                    hasCompletedOnboardingV2 = false
                }
            }
        } message: {
            Text("You'll see the introduction screens again the next time you launch the app.")
        }
        .alert("Restart VoiceInk to Apply Language", isPresented: $showLanguageRestartAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Your language change will take full effect after you quit and reopen VoiceInk.")
        }
    }
}
