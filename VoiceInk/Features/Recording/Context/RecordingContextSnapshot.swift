import AppKit
import Combine
import Foundation

struct RecordingContextSnapshot {
    var capturedAt = Date()
    var selectedText: String?
    var clipboardText: String?
    var screenText: String?
}

@MainActor
final class RecordingContextSnapshotStore {
    private(set) var snapshot = RecordingContextSnapshot()

    func updateSelectedText(_ text: String?) {
        snapshot.selectedText = Self.normalized(text)
    }

    func updateClipboardText(_ text: String?) {
        snapshot.clipboardText = Self.normalized(text)
    }

    func updateScreenText(_ text: String?) {
        snapshot.screenText = Self.normalized(text)
    }

    private static func normalized(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// One recording's context: the snapshot and the capture filling it. Captures what `resolveSources` asks for when
/// started and again whenever the mode changes, until the enhancement request takes the snapshot. Each source is
/// captured at most once.
@MainActor
final class RecordingContextCapture {
    typealias StartCapture = @MainActor (RecordingContextSources, RecordingContextSnapshotStore) -> [Task<Void, Never>]

    private let store = RecordingContextSnapshotStore()
    private let resolveSources: @MainActor () -> RecordingContextSources
    private let startCapture: StartCapture
    private var tasks: [Task<Void, Never>] = []
    private var modeChangeObserver: AnyCancellable?
    private var isFinished = false
    private(set) var requestedSources: RecordingContextSources = []

    init(
        resolveSources: @escaping @MainActor () -> RecordingContextSources,
        startCapture: @escaping StartCapture = RecordingContextCaptureService.startCapture
    ) {
        self.resolveSources = resolveSources
        self.startCapture = startCapture
    }

    func start<ModeChanges: Publisher>(followingModeChanges modeChanges: ModeChanges)
    where ModeChanges.Failure == Never {
        refresh()
        // `objectWillChange` fires before the change is stored, so resolve on a later main-actor turn.
        modeChangeObserver = modeChanges.sink { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    /// Starts capturing any source the current mode needs that has not been requested yet.
    func refresh() {
        guard !isFinished else { return }

        let newSources = resolveSources().subtracting(requestedSources)
        guard !newSources.isEmpty else { return }

        requestedSources.formUnion(newSources)
        tasks += startCapture(newSources, store)
    }

    /// Returns the snapshot for the enhancement request. It is read once, so nothing new starts afterwards.
    func finish() -> RecordingContextSnapshot {
        isFinished = true
        modeChangeObserver = nil
        return store.snapshot
    }

    func cancel() {
        isFinished = true
        modeChangeObserver = nil
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
    }
}

@MainActor
enum RecordingContextCaptureService {
    static func startCapture(
        _ sources: RecordingContextSources,
        into store: RecordingContextSnapshotStore
    ) -> [Task<Void, Never>] {
        var tasks: [Task<Void, Never>] = []

        if sources.contains(.clipboard) {
            tasks.append(
                Task { @MainActor in
                    store.updateClipboardText(NSPasteboard.general.string(forType: .string))
                })
        }

        if sources.contains(.selectedText) {
            tasks.append(
                Task { @MainActor in
                    guard !Task.isCancelled else { return }
                    let selectedText = await SelectedTextService.fetchSelectedText()
                    guard !Task.isCancelled else { return }
                    store.updateSelectedText(selectedText)
                })
        }

        if sources.contains(.screen) {
            tasks.append(
                Task { @MainActor in
                    guard CGPreflightScreenCaptureAccess(), !Task.isCancelled else { return }
                    let screenCaptureService = ScreenCaptureService()
                    let screenText = await screenCaptureService.captureAndExtractText()
                    guard !Task.isCancelled else { return }
                    store.updateScreenText(screenText)
                })
        }

        return tasks
    }
}
