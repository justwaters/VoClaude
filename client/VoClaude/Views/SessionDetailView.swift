import SwiftUI

struct SessionDetailView: View {
    let session: Session
    var onEdit: () -> Void

    @Environment(SessionStore.self) private var store
    @Environment(WebSocketManager.self) private var connections
    @Environment(AudioRecorder.self) private var recorder
    @AppStorage("onDeviceTranscription") private var onDeviceTranscription = false

    @State private var draft = ""
    @State private var isPressing = false
    @State private var recorderError: String?

    private var connection: SessionConnection? { connections.connections[session.id] }

    var body: some View {
        VStack(spacing: 0) {
            TranscriptView(messages: connection?.messages ?? [])
            Divider()
            controls
        }
        .navigationTitle(session.name)
        #if os(macOS)
        .navigationSubtitle(connection?.claudeSessionID.map { "Claude session \($0.prefix(8))" } ?? session.repoAlias)
        #endif
        .toolbar { toolbar }
        .task(id: session) {
            connections.activate(session, token: store.token(for: session.host))
        }
        .alert("Microphone", isPresented: .constant(recorderError != nil)) {
            Button("OK") { recorderError = nil }
        } message: {
            Text(recorderError ?? "")
        }
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 10) {
            statusLine
            HStack(alignment: .bottom, spacing: 12) {
                TextField("Message Claude…", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(sendDraft)
                    .disabled(!canSend)
                if connection?.isBusy == true {
                    Button("Stop", systemImage: "stop.circle.fill") {
                        connections.player.stop()
                        connection?.cancelTurn()
                    }
                    .labelStyle(.iconOnly)
                    .font(.title)
                    .foregroundStyle(.red)
                    .buttonStyle(.plain)
                } else if !draft.isEmpty {
                    Button("Send", systemImage: "arrow.up.circle.fill", action: sendDraft)
                        .labelStyle(.iconOnly)
                        .font(.title)
                        .buttonStyle(.plain)
                        .disabled(!canSend)
                        .keyboardShortcut(.return, modifiers: .command)
                }
            }
            pushToTalkButton
        }
        .padding()
        .background(.bar)
    }

    private var statusLine: some View {
        HStack(spacing: 10) {
            AudioVisualizerView(
                level: recorder.isRecording ? recorder.level : connections.player.level,
                isActive: recorder.isRecording || connections.player.isPlaying,
                tint: recorder.isRecording ? .red : .accentColor
            )
            Text(statusText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .contentTransition(.opacity)
            Spacer()
            if case .failed = connection?.state {
                Button("Reconnect") {
                    connection?.connect(token: store.token(for: session.host))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private var pushToTalkButton: some View {
        let recording = recorder.isRecording
        return ZStack {
            Circle()
                .fill(recording ? Color.red : Color.accentColor)
                .frame(width: 72, height: 72)
                .scaleEffect(recording ? 1.12 : 1)
                .shadow(color: (recording ? Color.red : .accentColor).opacity(0.35), radius: recording ? 14 : 6)
            Image(systemName: recording ? "waveform" : "mic.fill")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.white)
                .symbolEffect(.variableColor.iterative, isActive: recording)
        }
        .animation(.spring(duration: 0.25), value: recording)
        .opacity(canSend ? 1 : 0.4)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !isPressing, canSend else { return }
                    isPressing = true
                    startRecording()
                }
                .onEnded { _ in
                    guard isPressing else { return }
                    isPressing = false
                    stopRecording()
                }
        )
        .accessibilityElement()
        .accessibilityLabel(recording ? "Recording. Release to send." : "Hold to talk")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { recording ? stopRecording() : startRecording() }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem {
            Menu("Session", systemImage: "ellipsis.circle") {
                Button("New Claude Conversation", systemImage: "arrow.counterclockwise") {
                    connection?.resetConversation()
                }
                .disabled(connection?.state != .connected || connection?.isBusy == true)
                if let connection, !connection.voices.isEmpty {
                    Picker("Voice", systemImage: "person.wave.2", selection: voiceBinding(connection)) {
                        ForEach(connection.voices) { voice in
                            Text(voice.name).tag(voice.id)
                        }
                    }
                    .pickerStyle(.menu)
                }
                Button("Edit Session…", systemImage: "pencil", action: onEdit)
            }
        }
    }

    private func voiceBinding(_ connection: SessionConnection) -> Binding<String> {
        Binding {
            session.voice ?? connection.defaultVoice ?? connection.voices.first?.id ?? ""
        } set: { newValue in
            var updated = session
            updated.voice = newValue
            store.upsert(updated)
        }
    }

    // MARK: Actions

    private var canSend: Bool {
        connection?.state == .connected && connection?.isBusy == false
    }

    private var statusText: String {
        if recorder.isRecording { return "Listening…" }
        switch connection?.state {
        case .connecting, nil: return "Connecting…"
        case .disconnected: return "Disconnected"
        case .failed(let reason): return reason
        case .connected: break
        }
        switch connection?.activity ?? .idle {
        case .idle: return "Hold the mic to talk"
        case .transcribing: return "Transcribing…"
        case .thinking: return "Claude is working…"
        case .speaking: return "Speaking…"
        }
    }

    private func sendDraft() {
        guard canSend, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        connections.player.stop()
        connection?.sendPrompt(draft)
        draft = ""
    }

    private func startRecording() {
        connections.player.stop()
        Task {
            do {
                try await recorder.start(onDeviceTranscription: onDeviceTranscription)
                // Released before the mic came up (e.g. during the permission prompt).
                if !isPressing { recorder.cancel() }
            } catch {
                isPressing = false
                recorderError = error.localizedDescription
            }
        }
    }

    private func stopRecording() {
        Task {
            switch await recorder.stop() {
            case .audio(let pcm, let rate): connection?.sendAudio(pcm, sampleRate: rate)
            case .text(let text): connection?.sendPrompt(text)
            case nil: break
            }
        }
    }
}

// MARK: - Transcript

private struct TranscriptView: View {
    let messages: [Message]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(messages) { message in
                        MessageRow(message: message).id(message.id)
                    }
                }
                .padding()
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: messages.last?.text) {
                guard let last = messages.last else { return }
                proxy.scrollTo(last.id, anchor: .bottom)
            }
            .overlay {
                if messages.isEmpty {
                    ContentUnavailableView(
                        "Talk to Claude",
                        systemImage: "waveform.circle",
                        description: Text("Hold the mic button and ask Claude to work on this repo.")
                    )
                }
            }
        }
    }
}

private struct MessageRow: View {
    let message: Message

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 48)
                Text(message.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.accentColor, in: .rect(cornerRadius: 18))
                    .foregroundStyle(.white)
            }
        case .assistant:
            Text(Self.markdown(message.text))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .tool(let name):
            Label {
                Text("\(Text(name).bold()) \(message.text)")
                    .font(.caption.monospaced())
                    .lineLimit(3)
            } icon: {
                Image(systemName: "wrench.and.screwdriver")
            }
            .foregroundStyle(.secondary)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
        case .error:
            Label(message.text, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.red)
                .textSelection(.enabled)
        case .system:
            Text(message.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        }
    }

    private static func markdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
