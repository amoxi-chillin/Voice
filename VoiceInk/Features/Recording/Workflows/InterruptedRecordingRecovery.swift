import Foundation
import OSLog
import SwiftData

/// Keeps dictations interrupted by a quit, crash, or logout in History so they can be
/// retranscribed instead of lost.
@MainActor
enum InterruptedRecordingRecovery {
    private static let logger = Logger(
        subsystem: "com.prakashjoshipax.voiceink", category: "InterruptedRecordingRecovery")

    static var interruptedText: String {
        String(localized: "Recording interrupted. Use Retranscribe to transcribe the saved audio.")
    }

    static var noAudioText: String {
        String(localized: "Recording interrupted before any audio was saved.")
    }

    /// Recovers records and recordings left by a previous run. Must run before orphan audio cleanup.
    /// Only records and files older than `launchDate` are touched, so a recording started
    /// during this launch is never mistaken for an interrupted one.
    /// - Returns: The recovered History records.
    @discardableResult
    static func recover(modelContext: ModelContext, recordingsDirectory: URL, launchDate: Date) -> [Transcription] {
        let recovered =
            recoverPendingTranscriptions(modelContext: modelContext, launchDate: launchDate)
            + recoverOrphanRecordings(
                modelContext: modelContext,
                recordingsDirectory: recordingsDirectory,
                launchDate: launchDate
            )
        guard !recovered.isEmpty else { return [] }

        do {
            try modelContext.save()
            logger.notice("Recovered \(recovered.count, privacy: .public) interrupted recording(s)")
            return recovered
        } catch {
            logger.error("Failed to save recovered recordings: \(error, privacy: .public)")
            return []
        }
    }

    /// Recording records from an earlier launch that were never transcribed. Imported and
    /// retranscribed records are saved as pending too, but always with a transcription duration.
    private static func recoverPendingTranscriptions(
        modelContext: ModelContext,
        launchDate: Date
    ) -> [Transcription] {
        let pendingStatus: String? = TranscriptionStatus.pending.rawValue
        let descriptor = FetchDescriptor<Transcription>(
            predicate: #Predicate<Transcription> { transcription in
                transcription.transcriptionStatus == pendingStatus
                    && transcription.transcriptionDuration == nil
                    && transcription.timestamp < launchDate
            }
        )

        let transcriptions: [Transcription]
        do {
            transcriptions = try modelContext.fetch(descriptor)
        } catch {
            logger.error("Failed to fetch pending transcriptions: \(error, privacy: .public)")
            return []
        }

        for transcription in transcriptions {
            let outcome = transcription.audioFileURL
                .flatMap { URL(string: $0) }
                .flatMap { repairRecording(at: $0) }

            if let outcome {
                transcription.duration = outcome.duration
            }
            transcription.text = (outcome?.audioByteCount ?? 0) > 0 ? interruptedText : noAudioText
            transcription.transcriptionStatus = TranscriptionStatus.failed.rawValue
        }

        return transcriptions
    }

    /// Adds records for recordings whose app stopped before a record was saved. Only files with an
    /// unfinished header count as interrupted; complete orphans are left to orphan audio cleanup.
    private static func recoverOrphanRecordings(
        modelContext: ModelContext,
        recordingsDirectory: URL,
        launchDate: Date
    ) -> [Transcription] {
        var descriptor = FetchDescriptor<Transcription>()
        descriptor.propertiesToFetch = [\.audioFileURL]

        let referencedFiles: Set<String>
        do {
            referencedFiles = Set(
                try modelContext.fetch(descriptor).compactMap { transcription in
                    transcription.audioFileURL.flatMap { URL(string: $0) }?.lastPathComponent
                })
        } catch {
            logger.error("Failed to fetch transcription audio references: \(error, privacy: .public)")
            return []
        }

        guard
            let fileURLs = try? FileManager.default.contentsOfDirectory(
                at: recordingsDirectory,
                includingPropertiesForKeys: [.creationDateKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return []
        }

        var recovered: [Transcription] = []
        for fileURL in fileURLs
        where fileURL.pathExtension.lowercased() == "wav" && !referencedFiles.contains(fileURL.lastPathComponent) {
            guard let creationDate = try? fileURL.resourceValues(forKeys: [.creationDateKey]).creationDate,
                creationDate < launchDate,
                let outcome = repairRecording(at: fileURL),
                outcome.wasRepaired,
                outcome.audioByteCount > 0
            else {
                continue
            }

            let transcription = Transcription(
                text: interruptedText,
                duration: outcome.duration,
                audioFileURL: fileURL.absoluteString,
                transcriptionStatus: .failed
            )
            transcription.timestamp = creationDate
            modelContext.insert(transcription)
            recovered.append(transcription)
        }

        return recovered
    }

    private static func repairRecording(at url: URL) -> WAVHeaderRepair.Outcome? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        do {
            return try WAVHeaderRepair.repairIfNeeded(at: url)
        } catch {
            logger.error(
                "Failed to repair recording \(url.lastPathComponent, privacy: .public): \(error, privacy: .public)")
            return nil
        }
    }
}
