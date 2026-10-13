import SwiftUI

struct VoiceInputBar: View {
    let level: Float
    let status: String
    let countdown: Int?
    let isRecording: Bool
    let stop: () -> Void
    let cancel: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var samples = Array(repeating: CGFloat(0), count: 64)

    var body: some View {
        HStack(spacing: 22) {
            Image(systemName: "mic")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(MacVisualTokens.accent.opacity(0.72))
            Text(status).font(.system(size: 11, weight: .regular))
                .foregroundStyle(.secondary).frame(width: 180, alignment: .leading)
            if let countdown, isRecording {
                Text("静音 \(countdown) 秒后提交")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(MacVisualTokens.accent)
                    .accessibilityLabel("静音倒计时，还剩 \(countdown) 秒")
            }
            GeometryReader { geometry in
                HStack(spacing: max(2, (geometry.size.width - 96) / 63)) {
                    ForEach(samples.indices, id: \.self) { index in
                        Capsule()
                            .fill(MacVisualTokens.accent.opacity(0.20 + Double(samples[index]) * 0.48))
                            .frame(width: 1.5, height: 2 + samples[index] * 20)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(height: 28)
            .accessibilityLabel(isRecording ? "麦克风音量" : "语音识别中")
            Group {
                if isRecording {
                    Button("完成录音 ↵", action: stop)
                    .keyboardShortcut(.return, modifiers: [])
                    .help("按回车结束录音")
                    Button("取消", action: cancel)
                } else {
                    Button("取消", action: cancel)
                }
            }
                .font(.system(size: 11, weight: .medium))
                .buttonStyle(.borderless)
                .foregroundStyle(MacVisualTokens.accent.opacity(0.85))
                .padding(.horizontal, 8).padding(.vertical, 8)
        }
        .padding(.horizontal, 24)
        .frame(height: 64)
        .task(id: level) {
            while !Task.isCancelled, isRecording {
                samples.removeFirst()
                let incoming = CGFloat(min(1, max(0, level)))
                samples.append((samples.last ?? 0) * 0.4 + incoming * 0.6)
                do { try await Task.sleep(for: .milliseconds(60)) } catch { return }
            }
        }
        .onChange(of: isRecording) { recording in
            if !recording { samples = Array(repeating: 0, count: 64) }
        }
        .animation(reduceMotion ? nil : .linear(duration: 0.08), value: samples)
    }
}

struct KeySaveFeedbackView: View {
    let notice: AppNotice
    var body: some View {
        Label(notice.message, systemImage: notice.kind.icon)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(notice.kind.color)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .padding(12)
            .accessibilityLabel(notice.message)
    }
}
