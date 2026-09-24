import AudioToolbox
import Foundation
import SwiftData
import Testing
@testable import VoiceInk

@MainActor
final class InterruptedRecordingRecoveryTests {
    let container: ModelContainer
    let recordingsDirectory: URL
    let defaultsSuiteName = "InterruptedRecordingRecoveryTests-\(UUID().uuidString)"
    let defaults: UserDefaults

    init() throws {
        container = try ModelContainer(
            for: Transcription.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        recordingsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("InterruptedRecordingRecoveryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: defaultsSuiteName)!
    }

    deinit {
        try? FileManager.default.removeItem(at: recordingsDirectory)
        defaults.removePersistentDomain(forName: defaultsSuiteName)
    }

    private var context: ModelContext { container.mainContext }
    private var afterLaunch: Date { Date().addingTimeInterval(60) }

    @Test func marksPendingRecordingRetranscribable() throws {
        let audioURL = try writeUnclosedRecording(frameCount: 32_000)
        let transcription = insertPending(audioURL: audioURL)

        let count = recover(launchDate: afterLaunch)

        #expect(count == 1)
        #expect(transcription.transcriptionStatus == TranscriptionStatus.failed.rawValue)
        #expect(transcription.text == InterruptedRecordingRecovery.interruptedText)
        #expect(transcription.duration == 2.0)
    }

    @Test func ignoresFinishedRecordsSavedAsPending() throws {
        // Imports and History retranscriptions keep the default pending status once finished.
        let audioURL = recordingsDirectory.appendingPathComponent("retranscribed_\(UUID().uuidString).wav")
        ExtAudioFileDispose(try WAVFixture.writeRecording(to: audioURL, frameCount: 16_000))
        let transcription = Transcription(
            text: "Left knee pain for 3 days.",
            duration: 1.0,
            audioFileURL: audioURL.absoluteString,
            transcriptionDuration: 0.4
        )
        context.insert(transcription)

        let count = recover(launchDate: afterLaunch)

        #expect(count == 0)
        #expect(transcription.text == "Left knee pain for 3 days.")
        #expect(transcription.transcriptionStatus == TranscriptionStatus.pending.rawValue)
    }

    @Test func notesPendingRecordingWithoutAudio() throws {
        let transcription = insertPending(audioURL: recordingsDirectory.appendingPathComponent("missing.wav"))

        recover(launchDate: afterLaunch)

        #expect(transcription.text == InterruptedRecordingRecovery.noAudioText)
        #expect(transcription.transcriptionStatus == TranscriptionStatus.failed.rawValue)
    }

    @Test func ignoresRecordingStartedAfterLaunch() throws {
        let audioURL = try writeUnclosedRecording(frameCount: 16_000)
        let transcription = insertPending(audioURL: audioURL)

        let count = recover(launchDate: Date().addingTimeInterval(-60))

        #expect(count == 0)
        #expect(transcription.transcriptionStatus == TranscriptionStatus.pending.rawValue)
        #expect(try allTranscriptions().count == 1)
    }

    @Test func addsRecordForUnclosedOrphanRecording() throws {
        let audioURL = try writeUnclosedRecording(frameCount: 8_000)

        let count = recover(launchDate: afterLaunch)

        #expect(count == 1)
        let transcription = try #require(try allTranscriptions().first)
        // Compare file names: the temporary directory is reached through the /var symlink.
        let recoveredURL = try #require(transcription.audioFileURL.flatMap { URL(string: $0) })
        #expect(recoveredURL.lastPathComponent == audioURL.lastPathComponent)
        #expect(FileManager.default.fileExists(atPath: recoveredURL.path))
        #expect(transcription.text == InterruptedRecordingRecovery.interruptedText)
        #expect(transcription.transcriptionStatus == TranscriptionStatus.failed.rawValue)
        #expect(transcription.duration == 0.5)
    }

    @Test func leavesCompleteOrphanRecordingForCleanup() throws {
        let audioURL = recordingsDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        ExtAudioFileDispose(try WAVFixture.writeRecording(to: audioURL, frameCount: 8_000))

        let count = recover(launchDate: afterLaunch)

        #expect(count == 0)
        #expect(try allTranscriptions().isEmpty)
    }

    @Test func keepsTextOfNoteInterruptedWhileFinishing() throws {
        // A finished multi-part note is saved as pending with its combined text and no audio.
        let transcription = Transcription(
            text: "S: Left knee pain for 3 days.",
            duration: 42,
            transcriptionStatus: .pending
        )
        context.insert(transcription)

        recover(launchDate: afterLaunch)

        #expect(transcription.text == "S: Left knee pain for 3 days.")
        #expect(transcription.transcriptionStatus == TranscriptionStatus.completed.rawValue)
    }

    @Test func keepsRecoveredRecordsFromAutoDelete() throws {
        let audioURL = try writeUnclosedRecording(frameCount: 16_000)
        let transcription = insertPending(audioURL: audioURL)

        recover(launchDate: afterLaunch)

        #expect(InterruptedRecordingRecovery.keptTranscriptionIDs(defaults: defaults) == [transcription.id])
    }

    @Test func forgetsKeptRecordsOnceDeleted() throws {
        let audioURL = try writeUnclosedRecording(frameCount: 16_000)
        let transcription = insertPending(audioURL: audioURL)
        recover(launchDate: afterLaunch)

        context.delete(transcription)
        try context.save()
        recover(launchDate: afterLaunch)

        #expect(InterruptedRecordingRecovery.keptTranscriptionIDs(defaults: defaults).isEmpty)
    }

    // MARK: - Helpers

    @discardableResult
    private func recover(launchDate: Date) -> Int {
        InterruptedRecordingRecovery.recover(
            modelContext: context,
            recordingsDirectory: recordingsDirectory,
            launchDate: launchDate,
            defaults: defaults
        ).count
    }

    private func insertPending(audioURL: URL) -> Transcription {
        let transcription = Transcription(
            text: "",
            duration: 0,
            audioFileURL: audioURL.absoluteString,
            transcriptionStatus: .pending
        )
        context.insert(transcription)
        try? context.save()
        return transcription
    }

    /// Simulates a recording cut off by a crash: the file is never closed, so its header reports no audio.
    private func writeUnclosedRecording(frameCount: Int) throws -> URL {
        let url = recordingsDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        let fileRef = try WAVFixture.writeRecording(to: url, frameCount: frameCount)
        let data = try Data(contentsOf: url)
        ExtAudioFileDispose(fileRef)
        try data.write(to: url)
        return url
    }

    private func allTranscriptions() throws -> [Transcription] {
        try context.fetch(FetchDescriptor<Transcription>())
    }
}
