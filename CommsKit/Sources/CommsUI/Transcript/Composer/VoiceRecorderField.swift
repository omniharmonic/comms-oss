import CommsCore
import SwiftUI

/// The composer field while an audio message is being made (Messages): recording — a red dot,
/// the live waveform in red, the timer and a red stop button; recorded — play/pause, the
/// waveform, the length and the send arrow. The leading circle (Delete / Cancel) is the bar's.
struct VoiceRecorderField: View {
    let recorder: VoiceRecorder
    let fieldHeight: CGFloat
    let glyph: CGFloat
    let fontSize: CGFloat
    let sendSize: CGSize
    let sendBlue: Color
    let send: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            switch recorder.phase {
            case .recording:
                Circle().fill(.red).frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                LevelBars(levels: recorder.levels, color: .red, live: true)
                    .frame(height: fieldHeight * 0.55)
                Text(VoiceRecorder.timeString(recorder.elapsed))
                    .font(.system(size: fontSize - 2).monospacedDigit())
                    .foregroundStyle(.red)
                    .accessibilityLabel("Recording, \(VoiceRecorder.timeString(recorder.elapsed))")
                    .accessibilityIdentifier("recorder-time")
                Button { recorder.stop() } label: {
                    ZStack {
                        Circle().fill(.red)
                        RoundedRectangle(cornerRadius: 2).fill(.white).frame(width: sendSize.height * 0.36, height: sendSize.height * 0.36)
                    }
                    .frame(width: sendSize.height, height: sendSize.height)
                    .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop recording")
                .accessibilityIdentifier("recorder-stop")
            case .recorded:
                Button { recorder.togglePlayback() } label: {
                    Image(systemName: recorder.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: glyph - 3, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: sendSize.height, height: sendSize.height)
                        .background(Circle().fill(sendBlue))
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(recorder.isPlaying ? "Pause" : "Play")
                .accessibilityIdentifier("recorder-play")
                LevelBars(levels: recorder.levels, color: sendBlue, live: false)
                    .frame(height: fieldHeight * 0.55)
                Text(VoiceRecorder.timeString(recorder.elapsed))
                    .font(.system(size: fontSize - 2).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Audio message, \(VoiceRecorder.timeString(recorder.elapsed))")
                    .accessibilityIdentifier("recorder-time")
                Button(action: send) {
                    ZStack {
                        if recorder.isEncoding {
                            ProgressView(value: recorder.encodeProgress)
                                .progressViewStyle(.circular)
                                .controlSize(.small)
                                .tint(.white)
                        } else {
                            Image(systemName: "arrow.up")
                                .font(.system(size: glyph - 2, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(width: sendSize.width, height: sendSize.height)
                    .background(sendBlue.opacity(recorder.isEncoding ? 0.5 : 1), in: .capsule)
                }
                .buttonStyle(.plain)
                .disabled(recorder.isEncoding)
                .accessibilityLabel(recorder.isEncoding ? "Preparing audio message" : "Send audio message")
                .accessibilityIdentifier("recorder-send")
            case .failed(let message):
                Image(systemName: "mic.slash")
                    .foregroundStyle(.secondary)
                Text(message)
                    .font(.system(size: fontSize - 2))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            case .idle:
                EmptyView()
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, (fieldHeight - sendSize.height) / 2)
        .padding(.vertical, (fieldHeight - sendSize.height) / 2)
        .frame(maxWidth: .infinity, minHeight: fieldHeight)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("composer-recorder")
    }
}

/// Bars for audio levels (0…1). `live`: the newest levels at the trailing edge (they scroll in
/// while recording); otherwise the whole recording is spread over the width.
struct LevelBars: View {
    let levels: [Double]
    let color: Color
    let live: Bool

    var body: some View {
        Canvas { ctx, size in
            let bar: CGFloat = 2, gap: CGFloat = 2
            let count = max(1, Int((size.width + gap) / (bar + gap)))
            let values: [Double]
            if live {
                let tail = Array(levels.suffix(count))
                values = Array(repeating: 0, count: count - tail.count) + tail
            } else if levels.isEmpty {
                values = Array(repeating: 0, count: count)
            } else {
                values = (0..<count).map { i in levels[min(levels.count - 1, i * levels.count / count)] }
            }
            for (i, v) in values.enumerated() {
                let h = max(bar, CGFloat(v) * size.height)
                let rect = CGRect(x: CGFloat(i) * (bar + gap), y: (size.height - h) / 2, width: bar, height: h)
                ctx.fill(Path(roundedRect: rect, cornerRadius: bar / 2), with: .color(color))
            }
        }
        .accessibilityHidden(true)
    }
}
