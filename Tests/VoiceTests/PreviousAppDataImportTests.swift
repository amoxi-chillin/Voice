import Foundation
import SwiftData
import Testing
@testable import Voice

@MainActor
final class PreviousAppDataImportTests {
    let root: URL
    let locations: PreviousAppDataImport.Locations
    let settingsSuite = "PreviousAppDataImportTests-\(UUID().uuidString)"
    let previousSettingsSuite = "PreviousAppDataImportTests-previous-\(UUID().uuidString)"
    let defaults: UserDefaults

    init() throws {
        // A space, like "Application Support", so stored file URLs are percent-encoded.
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Previous App Import \(UUID().uuidString)", isDirectory: true)
        locations = PreviousAppDataImport.Locations(
            previousSupportDirectory: root.appendingPathComponent("com.prakashjoshipax.VoiceInk", isDirectory: true),
            supportDirectory: root.appendingPathComponent("com.amoxichillin.Voice", isDirectory: true),
            previousCustomSoundsDirectory: root.appendingPathComponent("VoiceInk/CustomSounds", isDirectory: true),
            customSoundsDirectory: root.appendingPathComponent("Voice/CustomSounds", isDirectory: true)
        )
        try FileManager.default.createDirectory(
            at: locations.previousSupportDirectory.appendingPathComponent("Recordings"),
            withIntermediateDirectories: true
        )
        defaults = UserDefaults(suiteName: settingsSuite)!
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: settingsSuite)
        UserDefaults(suiteName: previousSettingsSuite)?.removePersistentDomain(forName: previousSettingsSuite)
    }

    @Test func copiesHistoryAndPointsItAtCopiedRecordings() throws {
        let recording = try writePreviousFile("Recordings/note.wav")
        try withStore(at: previousStoreURL) { context in
            context.insert(
                Transcription(text: "Left knee pain.", duration: 3, audioFileURL: recording.absoluteString))
            try context.save()
        }

        let outcome = runImport()

        #expect(outcome.importedFiles)
        #expect(outcome.failedItems.isEmpty)
        let copiedRecording = locations.supportDirectory.appendingPathComponent("Recordings/note.wav")
        #expect(FileManager.default.fileExists(atPath: copiedRecording.path))
        try withStore(at: locations.supportDirectory.appendingPathComponent("default.store")) { context in
            let transcriptions = try context.fetch(FetchDescriptor<Transcription>())
            #expect(transcriptions.map(\.text) == ["Left knee pain."])
            #expect(transcriptions.first?.audioFileURL == copiedRecording.absoluteString)
        }
        try withStore(at: previousStoreURL) { context in
            let transcriptions = try context.fetch(FetchDescriptor<Transcription>())
            #expect(transcriptions.first?.audioFileURL == recording.absoluteString)
        }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: locations.supportDirectory.path)
            .filter { $0.hasPrefix(".importing-") }
        #expect(leftovers.isEmpty)
    }

    @Test func neverImportsOverVoiceData() throws {
        try writePreviousFile("Recordings/note.wav")
        try FileManager.default.createDirectory(at: locations.supportDirectory, withIntermediateDirectories: true)
        try Data("existing".utf8).write(to: locations.supportDirectory.appendingPathComponent("default.store"))

        let outcome = runImport()

        #expect(!outcome.importedFiles)
        #expect(!FileManager.default.fileExists(atPath: locations.supportDirectory.appendingPathComponent("Recordings").path))
        #expect(try String(contentsOf: markerURL, encoding: .utf8) == "done")
    }

    @Test func runsOnlyOnce() throws {
        try writePreviousFile("dashboard-stats-snapshot.json")
        runImport()
        try FileManager.default.removeItem(
            at: locations.supportDirectory.appendingPathComponent("dashboard-stats-snapshot.json"))

        let outcome = runImport()

        #expect(!outcome.importedFiles)
        #expect(
            !FileManager.default.fileExists(
                atPath: locations.supportDirectory.appendingPathComponent("dashboard-stats-snapshot.json").path))
    }

    @Test func finishesAnInterruptedImport() throws {
        try writePreviousFile("Recordings/note.wav")
        try writePreviousFile("dashboard-stats-snapshot.json", contents: "previous")
        try FileManager.default.createDirectory(at: locations.supportDirectory, withIntermediateDirectories: true)
        try "copying".write(to: markerURL, atomically: true, encoding: .utf8)
        try Data("already copied".utf8).write(
            to: locations.supportDirectory.appendingPathComponent("dashboard-stats-snapshot.json"))

        runImport()

        #expect(FileManager.default.fileExists(atPath: locations.supportDirectory.appendingPathComponent("Recordings/note.wav").path))
        #expect(
            try String(
                contentsOf: locations.supportDirectory.appendingPathComponent("dashboard-stats-snapshot.json"),
                encoding: .utf8) == "already copied")
        #expect(try String(contentsOf: markerURL, encoding: .utf8) == "done")
    }

    @Test func renamesRefineModelsAndCopiesCustomSounds() throws {
        try writePreviousFile("VoiceInkRefine/model/.voiceink-integrity.json")
        try FileManager.default.createDirectory(at: locations.previousCustomSoundsDirectory, withIntermediateDirectories: true)
        try Data("sound".utf8).write(to: locations.previousCustomSoundsDirectory.appendingPathComponent("start.wav"))

        runImport()

        let refine = locations.supportDirectory.appendingPathComponent("VoiceRefine/model")
        #expect(FileManager.default.fileExists(atPath: refine.appendingPathComponent(".voice-integrity.json").path))
        #expect(!FileManager.default.fileExists(atPath: refine.appendingPathComponent(".voiceink-integrity.json").path))
        #expect(FileManager.default.fileExists(atPath: locations.customSoundsDirectory.appendingPathComponent("start.wav").path))
    }

    @Test func importsSettingsWithRenamedNames() throws {
        let previous = UserDefaults(suiteName: previousSettingsSuite)!
        let modeJSON = try JSONSerialization.data(withJSONObject: [
            "aiProviderName": "VoiceInk Refine",
            "prompt": "Write like VoiceInk's examples",
        ])
        let recordingPath = locations.previousSupportDirectory.appendingPathComponent("Recordings/a.wav").path
        previous.set("VoiceInk Refine", forKey: "selectedAIProvider")
        previous.set(true, forKey: "VoiceInkChecksForUpdatesOnLaunch")
        previous.set(true, forKey: "SUEnableAutomaticChecks")
        previous.set(modeJSON, forKey: "modeConfigs")
        previous.set("claude -p \"$VOICEINK_FULL_PROMPT\"", forKey: "localCLICommand")
        previous.set(recordingPath, forKey: "lastRecording")

        let outcome = runImport()

        #expect(outcome.importedSettings)
        #expect(defaults.string(forKey: "selectedAIProvider") == "Voice Refine")
        #expect(defaults.bool(forKey: "VoiceChecksForUpdatesOnLaunch"))
        #expect(defaults.object(forKey: "VoiceInkChecksForUpdatesOnLaunch") == nil)
        #expect(defaults.object(forKey: "SUEnableAutomaticChecks") == nil)
        #expect(defaults.string(forKey: "localCLICommand") == "claude -p \"$VOICE_FULL_PROMPT\"")
        #expect(
            defaults.string(forKey: "lastRecording")
                == locations.supportDirectory.appendingPathComponent("Recordings/a.wav").path)
        let mode = try JSONSerialization.jsonObject(with: defaults.data(forKey: "modeConfigs")!) as? [String: String]
        #expect(mode == ["aiProviderName": "Voice Refine", "prompt": "Write like VoiceInk's examples"])
        #expect(previous.string(forKey: "selectedAIProvider") == "VoiceInk Refine")
    }

    @Test func leavesSettingsAloneOnceVoiceHasItsOwn() throws {
        UserDefaults(suiteName: previousSettingsSuite)!.set("VoiceInk Refine", forKey: "selectedAIProvider")
        defaults.set("Ollama", forKey: "selectedAIProvider")

        let outcome = runImport()

        #expect(!outcome.importedSettings)
        #expect(defaults.string(forKey: "selectedAIProvider") == "Ollama")
    }

    // MARK: - Helpers

    private var previousStoreURL: URL {
        locations.previousSupportDirectory.appendingPathComponent("default.store")
    }

    private var markerURL: URL {
        locations.supportDirectory.appendingPathComponent(PreviousAppDataImport.fileImportMarkerName)
    }

    @discardableResult
    private func runImport() -> PreviousAppDataImport.Outcome {
        PreviousAppDataImport.runIfNeeded(
            locations: locations,
            defaults: defaults,
            settingsDomain: settingsSuite,
            previousSettingsDomain: previousSettingsSuite
        )
    }

    @discardableResult
    private func writePreviousFile(_ relativePath: String, contents: String = "data") throws -> URL {
        let url = locations.previousSupportDirectory.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func withStore(at url: URL, _ body: (ModelContext) throws -> Void) throws {
        let container = try ModelContainer(
            for: Transcription.self,
            configurations: ModelConfiguration(url: url, cloudKitDatabase: .none)
        )
        try body(ModelContext(container))
    }
}
