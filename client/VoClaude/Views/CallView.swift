import SwiftUI

/// In-call screen: who you're talking to, what's happening, and phone-style controls.
struct CallView: View {
    @Environment(CallController.self) private var call
    @Environment(WebSocketManager.self) private var connections
    @Environment(AudioRecorder.self) private var recorder

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            VStack(spacing: 10) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 88))
                    .foregroundStyle(.tint)
                    .symbolEffect(.pulse, isActive: call.phase == .speaking || call.phase == .hearing)
                Text(call.session?.name ?? "VoClaude")
                    .font(.title.bold())
                if let connectedAt = call.connectedAt {
                    Text(connectedAt, style: .timer)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            AudioVisualizerView(
                level: call.phase == .speaking ? connections.player.level : recorder.level,
                isActive: call.phase == .speaking || call.phase == .hearing,
                tint: call.phase == .speaking ? .accentColor : .green
            )

            Text(statusText)
                .font(.headline)
                .foregroundStyle(.secondary)
                .contentTransition(.opacity)
                .animation(.default, value: call.phase)

            if let line = lastAssistantLine {
                Text(line)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }

            Spacer()

            HStack(spacing: 44) {
                CallButton(
                    title: call.isMuted ? "Unmute" : "Mute",
                    systemImage: call.isMuted ? "mic.slash.fill" : "mic.fill",
                    isOn: call.isMuted,
                    action: call.toggleMute
                )
                #if os(iOS)
                CallButton(
                    title: "Speaker",
                    systemImage: "speaker.wave.3.fill",
                    isOn: call.isSpeakerOn,
                    action: call.toggleSpeaker
                )
                #endif
                if connection?.isBusy == true {
                    CallButton(title: "Stop", systemImage: "stop.fill", isOn: false) {
                        connections.player.stop()
                        connection?.cancelTurn()
                    }
                }
            }

            Button(action: call.hangUp) {
                Image(systemName: "phone.down.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 76, height: 76)
                    .background(.red, in: .circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("End call")
            .padding(.bottom, 32)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 560)
        #endif
    }

    private var connection: SessionConnection? {
        call.session.flatMap { connections.connections[$0.id] }
    }

    private var statusText: String {
        if call.isMuted { return "Muted" }
        return switch call.phase {
        case .idle: "Call ended"
        case .connecting: "Connecting…"
        case .listening: "Listening"
        case .hearing: "Hearing you…"
        case .waiting: connection?.activity == .transcribing ? "Transcribing…" : "Claude is working…"
        case .speaking: "Claude is speaking"
        }
    }

    private var lastAssistantLine: String? {
        guard let message = connection?.messages.last(where: {
            if case .assistant = $0.role { true } else if case .tool = $0.role { true } else { false }
        }) else { return nil }
        if case .tool(let name) = message.role { return "\(name): \(message.text)" }
        return message.text.split(whereSeparator: \.isNewline).last.map(String.init)
    }
}

private struct CallButton: View {
    let title: String
    let systemImage: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 24))
                    .frame(width: 64, height: 64)
                    .foregroundStyle(isOn ? Color.black : Color.primary)
                    .background(isOn ? AnyShapeStyle(.white) : AnyShapeStyle(.quaternary), in: .circle)
                Text(title).font(.caption)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
