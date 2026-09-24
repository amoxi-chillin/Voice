import Foundation
import SwiftData
import os

/// Handles the full post-recording pipeline:
/// transcribe → filter → format → word-replace → AI enhance → deliver → save
@MainActor
class TranscriptionPipeline {
    struct AssistantHooks {
        let isFollowUp: Bool
        let sendFollowUp: (String, Transcription) async -> Void
        let startResponse: (String, EnhancementRuntimeConfiguration) async -> Void
        let showResponse: (String, String?) async -> Void
        let failResponse: (String) async -> Void

        static let inactive = AssistantHooks(
            isFollowUp: false,
            sendFollowUp: { _, _ in },
            startResponse: { _, _ in },
            showResponse: { _, _ in },
            failResponse: { _ in }
        )
    }

    /// Lets a mode collect several recordings into one note instead of delivering each one.
    struct NoteHooks {
        /// True when this recording adds to a note that is already open.
        let isContinuation: Bool
        /// Receives a finished part. The text is nil when the part failed to transcribe.
        let collect: (String?, Transcription, ModeConfig?, RecordingContextSnapshot?) async -> Void

        static let inactive = NoteHooks(isContinuation: false, collect: { _, _, _, _ in })
    }

    private let modelContext: ModelContext
    private let serviceRegistry: TranscriptionServiceRegistry
    private let enhancementService: AIEnhancementService?
    private let delivery = TranscriptionDelivery()
    private let logger = Logger(subsystem: "com.amoxichillin.voice", category: "TranscriptionPipeline")

    init(
        modelContext: ModelContext,
        serviceRegistry: TranscriptionServiceRegistry,
        enhancementService: AIEnhancementService?
    ) {
        self.modelContext = modelContext
        self.serviceRegistry = serviceRegistry
        self.enhancementService = enhancementService
    }

    /// Run the full pipeline for a given transcription record.
    /// - Parameters:
    ///   - transcription: The pending Transcription SwiftData object to populate and save.
    ///   - audioURL: The recorded audio file.
    ///   - transcriptionConfiguration: Mode-resolved transcription engine settings for this phase.
    ///   - session: An active streaming session if one was prepared, otherwise nil.
    ///   - onStateChange: Called when the pipeline moves to a new recording state (e.g. `.enhancing`).
    ///   - shouldCancel: Returns true if the user requested cancellation.
    ///   - onCancel: Called when cancellation is detected to cancel active session state.
    ///   - onDismiss: Called when delivery should close the recorder panel.
    func run(
        transcription: Transcription,
        audioURL: URL,
        transcriptionConfiguration: TranscriptionRuntimeConfiguration,
        formattingConfiguration resolveFormattingConfiguration: @escaping () -> TranscriptionFormattingConfiguration,
        session: TranscriptionSession?,
        triggerWordModeSelection: @escaping (String) -> String? = { _ in nil },
        enhancementConfiguration: @escaping () -> EnhancementRuntimeConfiguration?,
        recordingContextSnapshot: @escaping () async -> RecordingContextSnapshot? = { nil },
        outputConfiguration: @escaping () -> OutputRuntimeConfiguration,
        onStateChange: @escaping (RecordingState) -> Void,
        shouldCancel: () -> Bool,
        onCancel: @escaping () async -> Void,
        onDismiss: @escaping () async -> Void,
        assistant: AssistantHooks = .inactive,
        note: NoteHooks = .inactive
    ) async {
        let model = transcriptionConfiguration.model
        var finalText: String?
        var responseError: String?
        var outputForDelivery: OutputRuntimeConfiguration?
        var responseConfig: EnhancementRuntimeConfiguration?
        var shouldCollectIntoNote = note.isContinuation
        var noteMode: ModeConfig?

        func finishCanceledTranscription() async {
            await onCancel()

            let canceledDuration: TimeInterval?
            if transcription.duration > 0 {
                canceledDuration = nil
            } else {
                let duration = await AudioFileMetadata.duration(for: audioURL)
                canceledDuration = duration > 0 ? duration : nil
            }

            transcription.markAsCanceledTranscription(
                duration: canceledDuration,
                modelName: transcription.transcriptionModelName ?? model.displayName
            )

            do {
                try modelContext.save()
            } catch {
                logger.error("Failed to save canceled transcription: \(error, privacy: .public)")
            }
        }

        if shouldCancel() {
            await finishCanceledTranscription()
            return
        }

        do {
            let transcriptionStart = Date()
            var text: String
            if let session {
                text = try await session.transcribe(audioURL: audioURL)
            } else {
                text = try await serviceRegistry.transcribe(
                    audioURL: audioURL,
                    model: model,
                    context: transcriptionConfiguration.requestContext
                )
            }
            text = TranscriptionOutputFilter.filter(text)
            let transcriptionDuration = Date().timeIntervalSince(transcriptionStart)

            if shouldCancel() {
                await finishCanceledTranscription()
                return
            }

            text = text.trimmingCharacters(in: .whitespacesAndNewlines)

            if !assistant.isFollowUp,
                !note.isContinuation,
                let processedText = triggerWordModeSelection(text)
            {
                text = processedText
            }

            let formattingConfiguration = resolveFormattingConfiguration()
            let resolvedEnhancementConfiguration = enhancementConfiguration()
            let resolvedOutputConfiguration = outputConfiguration()
            let modeMetadata = metadata(
                for: formattingConfiguration.mode ?? resolvedEnhancementConfiguration?.mode
                    ?? resolvedOutputConfiguration.mode ?? transcriptionConfiguration.mode
            )

            if formattingConfiguration.isTextFormattingEnabled {
                text = ParagraphFormatter.format(text)
            }

            text = WordReplacementService.shared.applyReplacements(to: text, using: modelContext)
            let cleanedText = text

            let actualDuration = await AudioFileMetadata.duration(for: audioURL)

            transcription.text = cleanedText
            transcription.duration = actualDuration
            transcription.transcriptionModelName = model.displayName
            transcription.transcriptionDuration = transcriptionDuration
            transcription.modeName = modeMetadata.name
            transcription.modeEmoji = modeMetadata.emoji
            finalText = cleanedText

            if !assistant.isFollowUp,
                resolvedOutputConfiguration.outputMode != .respond,
                resolvedOutputConfiguration.mode?.continuation.isEnabled == true
            {
                shouldCollectIntoNote = true
            }
            noteMode = resolvedOutputConfiguration.mode

            if !assistant.isFollowUp && !shouldCollectIntoNote {
                let shouldRespondInRecorder =
                    resolvedOutputConfiguration.outputMode == .respond
                    && resolvedEnhancementConfiguration?.isEnabled == true
                    && resolvedEnhancementConfiguration.map { configuration in
                        enhancementService?.isConfigured(for: configuration) == true
                    } == true
                outputForDelivery = resolvedOutputConfiguration
                responseConfig = shouldRespondInRecorder ? resolvedEnhancementConfiguration : nil

                let isSkipShortEnhancementEnabled = UserDefaults.standard.bool(forKey: "SkipShortEnhancement")
                let savedThreshold = UserDefaults.standard.integer(forKey: "ShortEnhancementWordThreshold")
                let shortEnhancementWordThreshold = savedThreshold > 0 ? savedThreshold : 3
                let shouldSkipEnhancement =
                    !shouldRespondInRecorder && isSkipShortEnhancementEnabled
                    && WordCounter.count(in: text) <= shortEnhancementWordThreshold

                if let enhancementService,
                    let resolvedEnhancementConfiguration,
                    resolvedEnhancementConfiguration.isEnabled,
                    enhancementService.isConfigured(for: resolvedEnhancementConfiguration),
                    !shouldSkipEnhancement
                {
                    if shouldCancel() {
                        await finishCanceledTranscription()
                        return
                    }

                    onStateChange(.enhancing)
                    let textForAI = text
                    if shouldRespondInRecorder {
                        await assistant.startResponse(textForAI, resolvedEnhancementConfiguration)
                    }

                    let contextSnapshot = await recordingContextSnapshot()
                    let enhancement = await enhance(
                        textForAI,
                        transcription: transcription,
                        configuration: resolvedEnhancementConfiguration,
                        contextSnapshot: contextSnapshot,
                        using: enhancementService
                    )
                    if let enhancedText = enhancement.text {
                        finalText = enhancedText
                    } else {
                        responseError = enhancement.errorDescription
                        if shouldCancel() {
                            await finishCanceledTranscription()
                            return
                        }
                    }
                }
            }

            transcription.transcriptionStatus = TranscriptionStatus.completed.rawValue
        } catch {
            let errorDescription = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription

            if let nativeAppleError = error as? NativeAppleTranscriptionService.ServiceError,
                nativeAppleError.shouldShowNotification
            {
                await MainActor.run {
                    NotificationManager.shared.showNotification(
                        title: errorDescription,
                        type: .error,
                        duration: 5.0
                    )
                }
            }

            transcription.text = String(format: String(localized: "Transcription Failed: %@"), errorDescription)
            transcription.transcriptionStatus = TranscriptionStatus.failed.rawValue
        }

        func saveTranscriptionAndPostCompletion() {
            var didInsertSessionMetric = false

            if transcription.transcriptionStatus == TranscriptionStatus.completed.rawValue {
                do {
                    didInsertSessionMetric = try SessionMetricRecorder.recordRecorderSession(
                        transcription: transcription,
                        model: model,
                        in: modelContext
                    )
                } catch {
                    logger.error("Failed to record session metric: \(error, privacy: .public)")
                }
            }

            do {
                try modelContext.save()
                if didInsertSessionMetric {
                    NotificationCenter.default.post(name: .sessionMetricsDidChange, object: nil)
                }
                NotificationCenter.default.post(name: .transcriptionCompleted, object: transcription)
            } catch {
                logger.error("Failed to save transcription: \(error, privacy: .public)")
            }
        }

        if shouldCancel() {
            await finishCanceledTranscription()
            return
        }

        if shouldCollectIntoNote {
            saveTranscriptionAndPostCompletion()
            let didTranscribe = transcription.transcriptionStatus == TranscriptionStatus.completed.rawValue
            await note.collect(
                didTranscribe ? (finalText ?? "") : nil,
                transcription,
                noteMode,
                await recordingContextSnapshot()
            )
            return
        }

        await delivery.deliver(
            TranscriptionDelivery.Request(
                transcription: transcription,
                text: finalText,
                output: outputForDelivery ?? outputConfiguration(),
                responseConfig: responseConfig,
                responseError: responseError,
                isAssistantFollowUp: assistant.isFollowUp
            ),
            actions: TranscriptionDelivery.Actions(
                setState: onStateChange,
                dismiss: onDismiss,
                sendFollowUp: assistant.sendFollowUp,
                showResponse: assistant.showResponse,
                failResponse: assistant.failResponse
            )
        )

        saveTranscriptionAndPostCompletion()
    }

    /// Enhances and delivers a note that was collected from several recordings.
    func runNote(
        transcription: Transcription,
        text: String,
        enhancementConfiguration: EnhancementRuntimeConfiguration?,
        contextSnapshot: RecordingContextSnapshot?,
        outputConfiguration: OutputRuntimeConfiguration,
        targetBundleIdentifier: String?,
        onStateChange: @escaping (RecordingState) -> Void,
        shouldCancel: () -> Bool,
        onDismiss: @escaping () async -> Void
    ) async {
        var finalText = text

        if let enhancementService,
            let enhancementConfiguration,
            enhancementConfiguration.isEnabled,
            enhancementService.isConfigured(for: enhancementConfiguration)
        {
            onStateChange(.enhancing)
            let enhancement = await enhance(
                text,
                transcription: transcription,
                configuration: enhancementConfiguration,
                contextSnapshot: contextSnapshot,
                using: enhancementService
            )
            if let enhancedText = enhancement.text {
                finalText = enhancedText
            }
        }

        if shouldCancel() {
            // Every part already has its own History entry, so drop the combined one.
            modelContext.delete(transcription)
            try? modelContext.save()
            await onDismiss()
            return
        }

        transcription.transcriptionStatus = TranscriptionStatus.completed.rawValue

        await delivery.deliver(
            TranscriptionDelivery.Request(
                transcription: transcription,
                text: finalText,
                output: outputConfiguration,
                responseConfig: nil,
                responseError: nil,
                isAssistantFollowUp: false,
                expectedTargetBundleIdentifier: targetBundleIdentifier
            ),
            actions: TranscriptionDelivery.Actions(
                setState: onStateChange,
                dismiss: onDismiss,
                sendFollowUp: { _, _ in },
                showResponse: { _, _ in },
                failResponse: { _ in }
            )
        )

        // Session metrics were already recorded for each part.
        do {
            try modelContext.save()
            NotificationCenter.default.post(name: .transcriptionCompleted, object: transcription)
        } catch {
            logger.error("Failed to save note: \(error, privacy: .public)")
        }
    }

    /// Runs AI enhancement and records the outcome on `transcription`.
    private func enhance(
        _ text: String,
        transcription: Transcription,
        configuration: EnhancementRuntimeConfiguration,
        contextSnapshot: RecordingContextSnapshot?,
        using enhancementService: AIEnhancementService
    ) async -> (text: String?, errorDescription: String?) {
        do {
            transcription.aiEnhancementModelName =
                configuration.modelName
                ?? configuration.provider?.defaultModel
            transcription.promptName = configuration.prompt?.title
            let enhancementResult = try await enhancementService.enhance(
                text,
                configuration: configuration,
                contextSnapshot: contextSnapshot
            )
            transcription.enhancedText = enhancementResult.text
            transcription.promptName = enhancementResult.promptName ?? configuration.prompt?.title
            transcription.enhancementDuration = enhancementResult.duration
            transcription.aiRequestSystemMessage = enhancementResult.systemMessage
            transcription.aiRequestUserMessage = enhancementResult.userMessage
            return (enhancementResult.text, nil)
        } catch {
            let errorDescription = EnhancementFailureFormatter.description(for: error)
            let failureMessage = EnhancementFailureFormatter.message(description: errorDescription)
            transcription.enhancedText = failureMessage
            NotificationManager.shared.showNotification(
                title: failureMessage,
                type: .warning
            )
            return (nil, errorDescription)
        }
    }

    private func metadata(for mode: ModeConfig?) -> (name: String?, emoji: String?) {
        guard let mode, mode.isEnabled else {
            return (nil, nil)
        }

        return (mode.name, mode.icon.value)
    }
}
