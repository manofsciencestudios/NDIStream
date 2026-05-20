import SwiftUI

struct RecordControlRow: View {
    @ObservedObject var recorder: Recorder
    let isEnabled: Bool

    var body: some View {
        HStack(spacing: 10) {
            Button(action: toggle) {
                ZStack {
                    Circle()
                        .fill(Color.black.opacity(0.001))
                        .frame(width: 26, height: 26)
                    Circle()
                        .strokeBorder(isEnabled ? Color.red : Color.secondary, lineWidth: 2)
                        .frame(width: 22, height: 22)
                    if recorder.isRecording {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 12, height: 12)
                    }
                }
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled)
            .help(isEnabled ? (recorder.isRecording ? "Stop recording" : "Start recording") : "Recording available while live")

            Text(formatElapsed(recorder.elapsed))
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(recorder.isRecording ? .primary : .secondary)
                .frame(minWidth: 56, alignment: .leading)

            if let err = recorder.lastError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Button(action: { Recorder.revealRecordingsFolder() }) {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help("Reveal recordings folder")
        }
    }

    private func toggle() {
        if recorder.isRecording { recorder.stop() } else { recorder.start() }
    }

    private func formatElapsed(_ t: TimeInterval) -> String {
        let total = Int(t)
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }
}
