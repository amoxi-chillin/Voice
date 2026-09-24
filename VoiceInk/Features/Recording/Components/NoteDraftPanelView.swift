import SwiftUI

/// Shows a note that is collecting several recordings, with controls to finish or discard it.
struct NoteDraftPanelView: View {
    @ObservedObject var noteSession: DictationNoteSession
    let recordingState: RecordingState
    let onFinish: () -> Void
    let onDiscard: () -> Void

    static let height: CGFloat = 56

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(summary)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.92))
                    .lineLimit(1)

                status
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.6))
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            Button("Discard", action: onDiscard)
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.6))
                .disabled(recordingState != .idle)
                .help("Discard this note. Each part stays in History.")

            Button(action: onFinish) {
                Text("Finish")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.black)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.white.opacity(0.9)))
            }
            .buttonStyle(.plain)
            .help("Combine the parts and process the note now")
        }
        .padding(.horizontal, 14)
        .frame(height: Self.height)
        .help("Record again to add to this note")
        .accessibilityElement(children: .contain)
    }

    private var summary: String {
        let partCount = noteSession.parts.count
        let parts =
            partCount == 1
            ? String(localized: "1 part")
            : String(format: String(localized: "%d parts"), partCount)
        let duration = Duration.seconds(noteSession.totalDuration)
            .formatted(.time(pattern: .minuteSecond))
        return String(format: String(localized: "Note · %@ · %@"), parts, duration)
    }

    @ViewBuilder
    private var status: some View {
        switch recordingState {
        case .recording, .starting:
            Text("Recording part \(noteSession.parts.count + 1)")
        case .transcribing:
            Text(noteSession.finishWhenCurrentPartArrives ? "Adding the last part" : "Adding part")
        case .enhancing, .busy:
            Text("Working")
        case .idle:
            if let deadline = noteSession.finishDeadline {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let remaining = max(0, Int(deadline.timeIntervalSince(context.date).rounded(.up)))
                    Text("Finishing in \(remaining)s")
                }
            } else {
                Text("Record more, or Finish")
            }
        }
    }
}
