import SwiftData
import SwiftUI

struct DataSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var menuBarManager: MenuBarManager
    @EnvironmentObject private var recordingShortcutManager: RecordingShortcutManager
    @EnvironmentObject private var recorderUIManager: RecorderUIManager
    @EnvironmentObject private var transcriptionModelManager: TranscriptionModelManager
    @EnvironmentObject private var enhancementService: AIEnhancementService
    @ObservedObject private var mediaController = MediaController.shared
    @ObservedObject private var playbackController = PlaybackController.shared

    @AppStorage(CleanupSettingsKeys.isTranscriptionCleanupEnabled) private var isTranscriptionCleanupEnabled = false
    @AppStorage(CleanupSettingsKeys.transcriptionRetentionMinutes) private var transcriptionRetentionMinutes = 24 * 60
    @AppStorage(CleanupSettingsKeys.isAudioCleanupEnabled) private var isAudioCleanupEnabled = false
    @AppStorage(CleanupSettingsKeys.audioRetentionPeriod) private var audioRetentionPeriod = 7

    @State private var isPerformingAudioCleanup = false
    @State private var isShowingAudioConfirmation = false
    @State private var cleanupInfo: (fileCount: Int, totalSize: Int64, transcriptions: [Transcription]) = (0, 0, [])
    @State private var showAudioCleanupResult = false
    @State private var audioCleanupResult: (deletedCount: Int, errorCount: Int) = (0, 0)
    @State private var showTranscriptCleanupResult = false
    @State private var isImportingSettings = false

    var body: some View {
        Form {
            Section {
                Toggle("Delete Transcriptions Automatically", isOn: $isTranscriptionCleanupEnabled)

                if isTranscriptionCleanupEnabled {
                    Picker("Keep Transcriptions For", selection: $transcriptionRetentionMinutes) {
                        Text("Delete Immediately").tag(0)
                        Text("1 hour").tag(60)
                        Text("1 day").tag(24 * 60)
                        Text("3 days").tag(3 * 24 * 60)
                        Text("7 days").tag(7 * 24 * 60)
                    }

                    LabeledContent("Clean Up Transcriptions") {
                        Button("Run Now") {
                            Task {
                                await TranscriptionAutoCleanupService.shared.runManualCleanup(
                                    modelContext: modelContext)
                                await MainActor.run {
                                    showTranscriptCleanupResult = true
                                }
                            }
                        }
                    }
                } else {
                    Toggle("Delete Audio Automatically", isOn: $isAudioCleanupEnabled)

                    if isAudioCleanupEnabled {
                        Picker("Keep Audio For", selection: $audioRetentionPeriod) {
                            Text("1 day").tag(1)
                            Text("3 days").tag(3)
                            Text("7 days").tag(7)
                            Text("14 days").tag(14)
                            Text("30 days").tag(30)
                        }

                        LabeledContent("Clean Up Audio") {
                            Button(isPerformingAudioCleanup ? "Analyzing…" : "Run Now") {
                                analyzeAudioCleanup()
                            }
                            .disabled(isPerformingAudioCleanup)
                        }
                    }
                }
            } header: {
                Text("History")
            } footer: {
                if isTranscriptionCleanupEnabled {
                    Text("Deleting a transcription also deletes its audio recording.")
                } else {
                    Text("Keep your transcription history while removing older audio recordings.")
                }
            }

            Section("Backup") {
                LabeledContent {
                    Button("Export…") {
                        Task {
                            await ImportExportService.shared.exportSettings(
                                enhancementService: enhancementService,
                                recordingShortcutManager: recordingShortcutManager,
                                menuBarManager: menuBarManager,
                                mediaController: mediaController,
                                playbackController: playbackController,
                                recorderUIManager: recorderUIManager,
                                modelContext: modelContext
                            )
                        }
                    }
                } label: {
                    Text("Export Settings")
                    Text("Modes, dictionary, shortcuts and preferences.")
                }

                LabeledContent {
                    Button("Import…") {
                        guard !isImportingSettings else { return }
                        isImportingSettings = true
                        Task { @MainActor in
                            defer { isImportingSettings = false }
                            await ImportExportService.shared.importSettings(
                                enhancementService: enhancementService,
                                recordingShortcutManager: recordingShortcutManager,
                                menuBarManager: menuBarManager,
                                mediaController: mediaController,
                                playbackController: playbackController,
                                recorderUIManager: recorderUIManager,
                                modelContext: modelContext,
                                transcriptionModelManager: transcriptionModelManager
                            )
                        }
                    }
                    .disabled(isImportingSettings)
                } label: {
                    Text("Import Settings")
                    Text("Choose which categories to restore from a backup.")
                }
            }

            Section("Diagnostics") {
                LabeledContent("System Information") {
                    Button("Copy") {
                        SystemInfoService.shared.copySystemInfoToClipboard()
                    }
                }

                DiagnosticsSettingsView()
            }
        }
        .formStyle(.grouped)
        .alert("Transcript Cleanup", isPresented: $showTranscriptCleanupResult) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Cleanup complete.")
        }
        .alert("Audio Cleanup", isPresented: $isShowingAudioConfirmation) {
            Button("Cancel", role: .cancel) {}

            if cleanupInfo.fileCount > 0 {
                Button(String(localized: "Delete \(cleanupInfo.fileCount) Files"), role: .destructive) {
                    runAudioCleanup()
                }
            }
        } message: {
            if cleanupInfo.fileCount > 0 {
                Text(
                    String(
                        localized:
                            "This will delete \(cleanupInfo.fileCount) audio files (\(AudioCleanupManager.shared.formatFileSize(cleanupInfo.totalSize)))."
                    ))
            } else {
                Text(String(localized: "No audio files found older than \(audioRetentionPeriod) days."))
            }
        }
        .alert("Cleanup Complete", isPresented: $showAudioCleanupResult) {
            Button("OK", role: .cancel) {}
        } message: {
            if audioCleanupResult.errorCount > 0 {
                Text(
                    String(
                        format: String(localized: "Deleted files: %lld. Failed: %lld."),
                        Int64(audioCleanupResult.deletedCount), Int64(audioCleanupResult.errorCount)))
            } else {
                Text(String(localized: "Deleted \(audioCleanupResult.deletedCount) audio files."))
            }
        }
        .onChange(of: isTranscriptionCleanupEnabled) { _, newValue in
            if newValue {
                isAudioCleanupEnabled = false
                AudioCleanupManager.shared.stopAutomaticCleanup()
            } else if isAudioCleanupEnabled {
                AudioCleanupManager.shared.startAutomaticCleanup(modelContext: modelContext)
            }
        }
        .onChange(of: isAudioCleanupEnabled) { _, newValue in
            guard !isTranscriptionCleanupEnabled else {
                if newValue {
                    isAudioCleanupEnabled = false
                }
                AudioCleanupManager.shared.stopAutomaticCleanup()
                return
            }

            if newValue {
                AudioCleanupManager.shared.startAutomaticCleanup(modelContext: modelContext)
            } else {
                AudioCleanupManager.shared.stopAutomaticCleanup()
            }
        }
    }

    private func analyzeAudioCleanup() {
        Task {
            await MainActor.run { isPerformingAudioCleanup = true }
            let info = await AudioCleanupManager.shared.getCleanupInfo(modelContext: modelContext)
            await MainActor.run {
                cleanupInfo = info
                isPerformingAudioCleanup = false
                isShowingAudioConfirmation = true
            }
        }
    }

    private func runAudioCleanup() {
        Task {
            await MainActor.run { isPerformingAudioCleanup = true }
            let result = await AudioCleanupManager.shared.runCleanupForTranscriptions(
                modelContext: modelContext,
                transcriptions: cleanupInfo.transcriptions
            )
            await MainActor.run {
                audioCleanupResult = result
                isPerformingAudioCleanup = false
                showAudioCleanupResult = true
            }
        }
    }
}
