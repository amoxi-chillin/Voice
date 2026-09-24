import Combine
import Testing
@testable import VoiceInk

private func enhancement(
    isEnabled: Bool = true,
    provider: AIProvider? = .openAI,
    clipboard: Bool = false,
    selectedText: Bool = false,
    screen: Bool = false
) -> EnhancementRuntimeConfiguration {
    EnhancementRuntimeConfiguration(
        mode: nil,
        isEnabled: isEnabled,
        prompt: CustomPrompt(title: "Test", promptText: "Clean up the transcript."),
        provider: provider,
        modelName: nil,
        useClipboardContext: clipboard,
        useSelectedTextContext: selectedText,
        useScreenCaptureContext: screen
    )
}

private let allConfigured: (EnhancementRuntimeConfiguration) -> Bool = { _ in true }

struct RecordingContextCapturePolicyTests {
    @Test func capturesOnlyTheSourcesTheModeUses() {
        #expect(
            RecordingContextCapturePolicy.sources(usedBy: enhancement(clipboard: true), isConfigured: true)
                == .clipboard)
        #expect(
            RecordingContextCapturePolicy.sources(usedBy: enhancement(selectedText: true), isConfigured: true)
                == .selectedText)
        #expect(
            RecordingContextCapturePolicy.sources(usedBy: enhancement(screen: true), isConfigured: true)
                == .screen)
        #expect(
            RecordingContextCapturePolicy.sources(
                usedBy: enhancement(clipboard: true, selectedText: true, screen: true),
                isConfigured: true
            ) == [.clipboard, .selectedText, .screen])
        #expect(RecordingContextCapturePolicy.sources(usedBy: enhancement(), isConfigured: true).isEmpty)
    }

    @Test func capturesNothingWhenEnhancementIsOff() {
        let configuration = enhancement(isEnabled: false, clipboard: true, selectedText: true, screen: true)

        #expect(RecordingContextCapturePolicy.sources(usedBy: configuration, isConfigured: true).isEmpty)
    }

    @Test func capturesNothingWhenEnhancementCannotRun() {
        let unconfigured = enhancement(clipboard: true, selectedText: true, screen: true)
        let noProvider = enhancement(provider: nil, clipboard: true, selectedText: true, screen: true)

        #expect(RecordingContextCapturePolicy.sources(usedBy: unconfigured, isConfigured: false).isEmpty)
        #expect(RecordingContextCapturePolicy.sources(usedBy: noProvider, isConfigured: true).isEmpty)
    }

    @Test func capturesNothingForVoiceInkRefine() {
        let configuration = enhancement(provider: .voiceInkRefine, clipboard: true, selectedText: true, screen: true)

        #expect(RecordingContextCapturePolicy.sources(usedBy: configuration, isConfigured: true).isEmpty)
    }

    @Test func coversModesATriggerWordCanSwitchTo() {
        let sources = RecordingContextCapturePolicy.sourcesToCapture(
            current: enhancement(clipboard: true),
            triggerWordCandidates: [enhancement(screen: true), enhancement(isEnabled: false, selectedText: true)],
            isAssistantFollowUp: false,
            isConfigured: allConfigured
        )

        #expect(sources == [.clipboard, .screen])
    }

    @Test func checksEachModeIsConfigured() {
        let current = enhancement(clipboard: true)
        let triggerWordMode = enhancement(provider: .anthropic, screen: true)

        let sources = RecordingContextCapturePolicy.sourcesToCapture(
            current: current,
            triggerWordCandidates: [triggerWordMode],
            isAssistantFollowUp: false,
            isConfigured: { $0.provider != .anthropic }
        )

        #expect(sources == .clipboard)
    }

    @Test func assistantFollowUpsCaptureNothing() {
        let sources = RecordingContextCapturePolicy.sourcesToCapture(
            current: enhancement(clipboard: true, selectedText: true, screen: true),
            triggerWordCandidates: [enhancement(screen: true)],
            isAssistantFollowUp: true,
            isConfigured: allConfigured
        )

        #expect(sources.isEmpty)
    }

    @Test func triggerWordModesAreEnabledModesThatCanUseContext() {
        func mode(
            _ name: String,
            triggerWords: [String] = ["switch mode"],
            enhancement: Bool = true,
            clipboard: Bool = false,
            selectedText: Bool = false,
            screen: Bool = false
        ) -> ModeConfig {
            ModeConfig(
                name: name,
                triggerWords: triggerWords,
                isAIEnhancementEnabled: enhancement,
                useClipboardContext: clipboard,
                useSelectedTextContext: selectedText,
                useScreenCapture: screen
            )
        }

        var disabled = mode("Disabled", selectedText: true)
        disabled.isEnabled = false
        var blankTriggerWord = mode("Blank trigger word", selectedText: true)
        blankTriggerWord.triggerWords = ["  "]
        let modes = [
            mode("Clipboard", clipboard: true),
            mode("Selected text", selectedText: true),
            mode("Screen", screen: true),
            mode("No trigger word", triggerWords: [], selectedText: true),
            disabled,
            blankTriggerWord,
            mode("Enhancement off", enhancement: false, selectedText: true),
            mode("No context"),
        ]

        let candidates = RecordingContextCapturePolicy.triggerWordModesUsingContext(in: modes)

        #expect(candidates.map(\.name) == ["Clipboard", "Selected text", "Screen"])
    }
}

@MainActor
struct RecordingContextCaptureTests {
    @MainActor
    private final class Harness {
        var sources: RecordingContextSources = []
        var startedCaptures: [RecordingContextSources] = []

        func makeCapture() -> RecordingContextCapture {
            RecordingContextCapture(
                resolveSources: { [unowned self] in self.sources },
                startCapture: { [unowned self] sources, store in
                    self.startedCaptures.append(sources)
                    if sources.contains(.clipboard) {
                        store.updateClipboardText("clipboard text")
                    }
                    return []
                }
            )
        }
    }

    @Test func startsNothingWhenTheModeUsesNoContext() {
        let harness = Harness()
        let capture = harness.makeCapture()

        capture.start(followingModeChanges: Empty<Void, Never>())

        #expect(harness.startedCaptures.isEmpty)
        #expect(capture.finish().clipboardText == nil)
    }

    @Test func addsOnlyNewSourcesWhenTheModeChanges() {
        let harness = Harness()
        harness.sources = .selectedText
        let capture = harness.makeCapture()

        capture.start(followingModeChanges: Empty<Void, Never>())
        harness.sources = [.selectedText, .clipboard]
        capture.refresh()
        harness.sources = .selectedText
        capture.refresh()

        #expect(harness.startedCaptures == [.selectedText, .clipboard])
        #expect(capture.requestedSources == [.selectedText, .clipboard])
        #expect(capture.finish().clipboardText == "clipboard text")
    }

    @Test func followsModeChangesUntilFinished() async {
        let harness = Harness()
        let modeChanges = PassthroughSubject<Void, Never>()
        let capture = harness.makeCapture()

        capture.start(followingModeChanges: modeChanges)
        harness.sources = .screen
        modeChanges.send()
        for _ in 0..<100 where harness.startedCaptures.isEmpty {
            await Task.yield()
        }

        #expect(harness.startedCaptures == [.screen])

        _ = capture.finish()
        harness.sources = .clipboard
        modeChanges.send()
        capture.refresh()
        for _ in 0..<10 {
            await Task.yield()
        }

        #expect(harness.startedCaptures == [.screen])
    }

    @Test func cancelStopsFurtherCapture() {
        let harness = Harness()
        let capture = harness.makeCapture()

        capture.start(followingModeChanges: Empty<Void, Never>())
        capture.cancel()
        harness.sources = .clipboard
        capture.refresh()

        #expect(harness.startedCaptures.isEmpty)
    }
}
