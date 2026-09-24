import Foundation

/// Collects several recordings into one note so they are enhanced and delivered together.
///
/// Each part keeps its own History entry with the raw transcript, so a discarded or
/// interrupted note never loses what was dictated.
@MainActor
final class DictationNoteSession: ObservableObject {
    struct Part: Identifiable {
        let id: UUID
        let text: String
        let duration: TimeInterval
    }

    struct Snapshot {
        let mode: ModeConfig
        let parts: [Part]
        let targetBundleIdentifier: String?

        var combinedText: String {
            parts.map(\.text).joined(separator: "\n\n")
        }

        var totalDuration: TimeInterval {
            parts.reduce(0) { $0 + $1.duration }
        }
    }

    @Published private(set) var parts: [Part] = []
    @Published private(set) var finishDeadline: Date?
    @Published private(set) var mode: ModeConfig?

    /// Context captured with the first part, used when the note is enhanced.
    private(set) var contextSnapshot: RecordingContextSnapshot?
    /// The app that was frontmost when the latest part stopped recording.
    private(set) var targetBundleIdentifier: String?
    /// Set when Finish is requested while a part is still being recorded or transcribed.
    var finishWhenCurrentPartArrives = false

    private var finishTask: Task<Void, Never>?

    var isActive: Bool {
        mode != nil
    }

    var totalDuration: TimeInterval {
        parts.reduce(0) { $0 + $1.duration }
    }

    var continuation: DictationContinuation {
        mode?.continuation ?? .off
    }

    func begin(mode: ModeConfig, contextSnapshot: RecordingContextSnapshot?) {
        self.mode = mode
        self.contextSnapshot = contextSnapshot
    }

    func append(_ part: Part, targetBundleIdentifier: String?) {
        parts.append(part)
        if let targetBundleIdentifier {
            self.targetBundleIdentifier = targetBundleIdentifier
        }
    }

    /// Starts the countdown to finish the note, if the mode uses a timed wait.
    func scheduleFinish(_ finish: @escaping @MainActor () async -> Void) {
        cancelCountdown()

        guard case .timed(let seconds) = continuation else { return }

        let deadline = Date().addingTimeInterval(TimeInterval(seconds))
        finishDeadline = deadline
        finishTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(seconds))
            } catch {
                return
            }
            guard let self, self.finishDeadline == deadline else { return }
            await finish()
        }
    }

    func cancelCountdown() {
        finishTask?.cancel()
        finishTask = nil
        finishDeadline = nil
    }

    /// Ends the session and returns what was collected, or nil if nothing was.
    func takeSnapshot() -> Snapshot? {
        defer { reset() }
        guard let mode, !parts.isEmpty else { return nil }
        return Snapshot(mode: mode, parts: parts, targetBundleIdentifier: targetBundleIdentifier)
    }

    func reset() {
        cancelCountdown()
        parts = []
        mode = nil
        contextSnapshot = nil
        targetBundleIdentifier = nil
        finishWhenCurrentPartArrives = false
    }
}
