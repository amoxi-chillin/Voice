import Foundation

struct RecordingContextSources: OptionSet, Hashable {
    let rawValue: Int

    static let clipboard = RecordingContextSources(rawValue: 1 << 0)
    static let selectedText = RecordingContextSources(rawValue: 1 << 1)
    static let screen = RecordingContextSources(rawValue: 1 << 2)
}

/// Decides which context a recording captures, so the clipboard, selected text (which can trigger the frontmost
/// app's Copy command) and the active window are only read when the enhancement request will include them.
///
/// When the mode is decided:
/// - App and URL modes are applied before capture starts: the engine awaits
///   `ActiveWindowService.beginApplyingConfiguration` first.
/// - A mode picked while recording (⌥-number shortcuts, the recorder's mode menu, the menu bar) or a mode edit
///   adds the sources it needs from that moment, until the enhancement request takes the snapshot.
/// - A trigger word is only known after transcription, too late to capture then, so every mode a trigger word
///   can select is covered up front.
enum RecordingContextCapturePolicy {
    /// Sources to capture for a recording: those of the current mode plus those of every mode a trigger word in
    /// the transcript could switch to. Assistant follow-ups reuse the first turn's system prompt and never build
    /// an enhancement request, so they capture nothing.
    static func sourcesToCapture(
        current: EnhancementRuntimeConfiguration,
        triggerWordCandidates: [EnhancementRuntimeConfiguration],
        isAssistantFollowUp: Bool,
        isConfigured: (EnhancementRuntimeConfiguration) -> Bool
    ) -> RecordingContextSources {
        guard !isAssistantFollowUp else { return [] }

        return ([current] + triggerWordCandidates).reduce(into: []) { sources, configuration in
            sources.formUnion(self.sources(usedBy: configuration, isConfigured: isConfigured(configuration)))
        }
    }

    /// Sources the enhancement request for `configuration` reads. Nothing unless enhancement runs (enabled and
    /// configured, as `TranscriptionPipeline` requires) with a provider that takes context; VoiceInk Refine sends
    /// only the transcript. Otherwise the mode's own context switches, as `AIEnhancementService` applies them.
    static func sources(
        usedBy configuration: EnhancementRuntimeConfiguration,
        isConfigured: Bool
    ) -> RecordingContextSources {
        guard configuration.isEnabled,
            isConfigured,
            let provider = configuration.provider,
            provider != .voiceInkRefine
        else {
            return []
        }

        var sources: RecordingContextSources = []
        if configuration.useClipboardContext {
            sources.insert(.clipboard)
        }
        if configuration.useSelectedTextContext {
            sources.insert(.selectedText)
        }
        if configuration.useScreenCaptureContext {
            sources.insert(.screen)
        }
        return sources
    }

    /// Modes a trigger word can switch to (those `ModeTriggerWordDetectionService` matches against) that turn on
    /// enhancement and at least one context source. No other mode can add sources, so the rest are not resolved.
    static func triggerWordModesUsingContext(in modes: [ModeConfig]) -> [ModeConfig] {
        modes.filter { mode in
            mode.isEnabled
                && mode.triggerWords.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                && mode.isAIEnhancementEnabled
                && (mode.useClipboardContext || mode.useSelectedTextContext || mode.useScreenCapture)
        }
    }
}
