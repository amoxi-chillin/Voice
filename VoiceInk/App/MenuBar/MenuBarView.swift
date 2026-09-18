import CoreAudio
import SwiftUI

struct MenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject var engine: VoiceInkEngine
    @EnvironmentObject var recorderUIManager: RecorderUIManager
    @EnvironmentObject var transcriptionModelManager: TranscriptionModelManager
    @EnvironmentObject var whisperModelManager: WhisperModelManager
    @EnvironmentObject var recordingShortcutManager: RecordingShortcutManager
    @EnvironmentObject var menuBarManager: MenuBarManager
    @EnvironmentObject var mainWindowNavigation: MainWindowNavigation
    @EnvironmentObject var updaterViewModel: UpdaterViewModel
    @EnvironmentObject var enhancementService: AIEnhancementService
    @EnvironmentObject var aiService: AIService
    @ObservedObject private var launchAtLoginManager = LaunchAtLoginManager.shared
    @ObservedObject private var modeManager = ModeManager.shared
    @ObservedObject var audioDeviceManager = AudioDeviceManager.shared
    @AppStorage(OnboardingSettings.completedV2Key) private var hasCompletedOnboardingV2 = false

    var body: some View {
        VStack {
            if hasCompletedOnboardingV2 {
                completedOnboardingMenu
            } else {
                onboardingMenu
            }
        }
    }

    private var onboardingMenu: some View {
        Group {
            Button("Complete Onboarding") {
                showMainWindow()
            }

            Divider()

            Button("Quit VoiceInk") {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    private var completedOnboardingMenu: some View {
        Group {
            Button(isRecording ? "Stop Dictation" : "Start Dictation") {
                recorderUIManager.handleToggleRecorderPanelNotification()
            }

            Divider()

            Menu(String(format: String(localized: "Mode: %@"), activeModeName)) {
                if modeManager.enabledConfigurations.isEmpty {
                    Text("No modes available")
                } else {
                    Picker("Mode", selection: activeModeSelection) {
                        ForEach(modeManager.enabledConfigurations) { config in
                            Text(config.name).tag(Optional(config.id))
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                Divider()

                Button("Manage Modes…") {
                    showMainWindowAndNavigate(to: .modes)
                }

                Button("Manage Models…") {
                    showMainWindowAndNavigate(to: .models)
                }
            }

            Menu(String(format: String(localized: "Audio Input: %@"), currentDeviceName)) {
                if audioDeviceManager.availableDevices.isEmpty {
                    Text("No devices available")
                } else {
                    Picker("Audio Input", selection: audioInputSelection) {
                        ForEach(audioDeviceManager.availableDevices, id: \.id) { device in
                            Text(device.name).tag(device.id)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                Divider()

                Button("Audio Settings…") {
                    SettingsWindowPresenter.open(.audio)
                }
            }

            Divider()

            Button("Retry Last Transcription") {
                LastTranscriptionService.retryLastTranscription(
                    from: engine.modelContext,
                    transcriptionModelManager: transcriptionModelManager,
                    serviceRegistry: engine.serviceRegistry,
                    enhancementService: enhancementService
                )
            }

            Button("Copy Last Transcription") {
                LastTranscriptionService.copyLastTranscription(from: engine.modelContext)
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])

            Button("Quick History") {
                menuBarManager.openQuickHistory()
            }
            .keyboardShortcut("h", modifiers: [.command, .shift])

            Divider()

            Toggle(
                "Launch at Login",
                isOn: Binding(
                    get: { launchAtLoginManager.isEnabled },
                    set: { launchAtLoginManager.setEnabled($0) }
                )
            )
            .disabled(launchAtLoginManager.isUpdating)

            Toggle(
                "Hide Dock Icon",
                isOn: Binding(
                    get: { menuBarManager.isMenuBarOnly },
                    set: { isMenuBarOnly in
                        menuBarManager.isMenuBarOnly = isMenuBarOnly
                        if !isMenuBarOnly {
                            showMainWindow()
                        }
                    }
                )
            )
            .keyboardShortcut("d", modifiers: [.command, .shift])

            Divider()

            Button("Open VoiceInk") {
                showMainWindow()
            }

            Button("Settings…") {
                SettingsWindowPresenter.open()
            }
            .keyboardShortcut(",", modifiers: .command)

            Button("Check for Updates…") {
                updaterViewModel.checkForUpdates()
            }
            .disabled(!updaterViewModel.canCheckForUpdates)

            Divider()

            Button("Quit VoiceInk") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
    }

    private var isRecording: Bool {
        engine.recordingState == .recording
    }

    private var activeModeName: String {
        modeManager.currentEffectiveConfiguration?.name ?? String(localized: "None")
    }

    private var activeModeSelection: Binding<UUID?> {
        Binding(
            get: { modeManager.currentEffectiveConfiguration?.id },
            set: { id in
                guard let config = modeManager.enabledConfigurations.first(where: { $0.id == id }) else { return }
                modeManager.setActiveConfiguration(config)
            }
        )
    }

    private var currentDeviceName: String {
        let currentID = audioDeviceManager.getCurrentDevice()
        return audioDeviceManager.availableDevices.first { $0.id == currentID }?.name
            ?? String(localized: "None")
    }

    private var audioInputSelection: Binding<AudioDeviceID> {
        Binding(
            get: { audioDeviceManager.getCurrentDevice() },
            set: { audioDeviceManager.selectDeviceAndSwitchToCustomMode(id: $0) }
        )
    }

    private func showMainWindow() {
        let existingWindow = WindowManager.shared.currentMainWindow()
        menuBarManager.activateForPresentedWindow()

        if existingWindow == nil {
            WindowManager.shared.prepareForUserRequestedMainWindow()
            openWindow(id: AppWindowID.main)
        } else {
            openWindow(id: AppWindowID.main)
            WindowManager.shared.showMainWindow()
        }
    }

    private func showMainWindowAndNavigate(to destination: ViewType) {
        mainWindowNavigation.navigate(to: destination)
        showMainWindow()
    }
}
