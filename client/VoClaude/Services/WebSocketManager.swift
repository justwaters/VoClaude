import Foundation
import Observation

/// Keeps one WebSocket per session open so switching repos doesn't interrupt a running turn.
/// Only the active session's audio is played.
@MainActor
@Observable
final class WebSocketManager {
    private(set) var connections: [Session.ID: SessionConnection] = [:]
    private(set) var activeID: Session.ID?

    @ObservationIgnored let player: AudioPlayer

    init(player: AudioPlayer) {
        self.player = player
    }

    var active: SessionConnection? {
        activeID.flatMap { connections[$0] }
    }

    /// Make `session` the foreground session, connecting if needed.
    @discardableResult
    func activate(_ session: Session, token: String?) -> SessionConnection {
        let connection = connection(for: session, token: token)
        if activeID != session.id {
            player.stop()
            active?.isActive = false
            activeID = session.id
        }
        connection.isActive = true
        if connection.state.canConnect {
            connection.connect(token: token)
        }
        return connection
    }

    func deactivate() {
        player.stop()
        active?.isActive = false
        activeID = nil
    }

    func remove(_ id: Session.ID) {
        connections.removeValue(forKey: id)?.disconnect()
        if activeID == id { deactivate() }
    }

    private func connection(for session: Session, token: String?) -> SessionConnection {
        if let existing = connections[session.id] {
            if existing.session.webSocketURL == session.webSocketURL && existing.token == token {
                existing.session = session  // name/voice edits don't need a new socket
                return existing
            }
            // Host, alias or token changed: start over with a fresh socket.
            existing.disconnect()
        }
        let connection = SessionConnection(session: session, token: token)
        connection.onAudio = { [weak self, weak connection] data, rate in
            guard let self, let connection, connection.isActive else { return }
            self.player.enqueue(pcm16: data, sampleRate: rate)
        }
        connections[session.id] = connection
        return connection
    }
}

@MainActor
@Observable
final class SessionConnection {
    enum State: Equatable {
        case disconnected
        case connecting
        case connected
        case failed(String)

        var canConnect: Bool {
            switch self {
            case .disconnected, .failed: true
            case .connecting, .connected: false
            }
        }
    }

    enum Activity: String {
        case idle, transcribing, thinking, speaking
    }

    var session: Session
    let token: String?

    private(set) var state: State = .disconnected
    private(set) var activity: Activity = .idle
    private(set) var messages: [Message] = []
    private(set) var claudeSessionID: String?
    private(set) var lastCostUSD: Double?
    private(set) var voices: [VoiceOption] = []
    private(set) var defaultVoice: String?
    var isActive = false

    var isBusy: Bool { activity != .idle }

    @ObservationIgnored var onAudio: ((Data, Double) -> Void)?
    @ObservationIgnored private var task: URLSessionWebSocketTask?
    @ObservationIgnored private var receiveLoop: Task<Void, Never>?
    @ObservationIgnored private var keepAlive: Task<Void, Never>?
    /// Index of the assistant message currently receiving text deltas.
    @ObservationIgnored private var openAssistantIndex: Int?
    /// Index of the "voice message" placeholder awaiting its server transcript.
    @ObservationIgnored private var pendingVoiceIndex: Int?

    init(session: Session, token: String?) {
        self.session = session
        self.token = token
    }

    // MARK: Connection

    func connect(token: String?) {
        guard state.canConnect else { return }
        guard let url = session.webSocketURL else {
            state = .failed("Invalid host “\(session.host)”")
            return
        }
        var request = URLRequest(url: url)
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let task = URLSession.shared.webSocketTask(with: request)
        task.maximumMessageSize = 32 * 1024 * 1024
        self.task = task
        state = .connecting
        task.resume()

        receiveLoop = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await task.receive()
                    self?.handle(message)
                } catch {
                    self?.didDisconnect(task: task, error: error)
                    return
                }
            }
        }
        keepAlive = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled else { return }
                self?.send(["type": "ping"])
            }
        }
    }

    func disconnect() {
        receiveLoop?.cancel()
        keepAlive?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        state = .disconnected
        activity = .idle
        closeTurn()
    }

    private func didDisconnect(task: URLSessionWebSocketTask, error: Error) {
        guard task === self.task else { return }
        keepAlive?.cancel()
        self.task = nil
        activity = .idle
        closeTurn()
        state = .failed(Self.describe(closeCode: task.closeCode, reason: task.closeReason, error: error))
    }

    private static func describe(closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?, error: Error) -> String {
        if let reason, let text = String(data: reason, encoding: .utf8), !text.isEmpty {
            return text
        }
        switch closeCode.rawValue {
        case 1008: return "Invalid token"
        case 4404: return "Unknown repo alias"
        default:
            let message = (error as NSError).localizedDescription
            // A handshake rejected with HTTP 403 surfaces as a generic "bad server response".
            return message.contains("bad server response") ? "Connection rejected (check the token)" : message
        }
    }

    // MARK: Sending

    func sendPrompt(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        messages.append(Message(role: .user, text: text))
        closeTurn()
        activity = .thinking
        send(withVoice(["type": "text", "content": text]))
    }

    func sendAudio(_ pcm: Data, sampleRate: Double) {
        messages.append(Message(role: .user, text: "🎙️ …"))
        pendingVoiceIndex = messages.count - 1
        closeTurn()
        activity = .transcribing
        send(withVoice([
            "type": "audio",
            "data": pcm.base64EncodedString(),
            "sample_rate": Int(sampleRate),
            "format": "pcm_s16le",
        ]))
    }

    private func withVoice(_ payload: [String: Any]) -> [String: Any] {
        guard let voice = session.voice else { return payload }
        return payload.merging(["voice": voice]) { $1 }
    }

    func cancelTurn() {
        send(["type": "cancel"])
    }

    func resetConversation() {
        send(["type": "reset"])
        messages.append(Message(role: .system, text: "Started a new Claude session"))
    }

    private func send(_ payload: [String: Any]) {
        guard let task else {
            if payload["type"] as? String != "ping" {
                appendError("Not connected")
                activity = .idle
            }
            return
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let string = String(data: data, encoding: .utf8) else { return }
        task.send(.string(string)) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in self?.appendError("Send failed: \(error.localizedDescription)") }
        }
    }

    // MARK: Receiving

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .string(let string): data = Data(string.utf8)
        case .data(let raw): data = raw
        @unknown default: return
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let event = try? decoder.decode(ServerEvent.self, from: data) else { return }
        apply(event)
    }

    private func apply(_ event: ServerEvent) {
        switch event.type {
        case "session":
            state = .connected
            claudeSessionID = event.sessionId
            voices = event.voices ?? []
            defaultVoice = event.defaultVoice

        case "status":
            switch event.state {
            case "transcribing": activity = .transcribing
            case "thinking": activity = .thinking
            case "speaking": activity = .speaking
            case "done":
                activity = .idle
                closeTurn()
            default: break
            }

        case "user_transcript":
            let text = event.content ?? ""
            if let index = pendingVoiceIndex, messages.indices.contains(index) {
                messages[index].text = text.isEmpty ? "🎙️ (no speech detected)" : text
            }
            pendingVoiceIndex = nil

        case "text":
            guard let delta = event.content else { return }
            if let index = openAssistantIndex, messages.indices.contains(index) {
                messages[index].text += delta
            } else {
                messages.append(Message(role: .assistant, text: delta.trimmingLeadingNewlines()))
                openAssistantIndex = messages.count - 1
            }

        case "tool":
            openAssistantIndex = nil
            messages.append(Message(role: .tool(name: event.name ?? "Tool"), text: event.summary ?? ""))

        case "audio":
            guard let base64 = event.data, let pcm = Data(base64Encoded: base64) else { return }
            onAudio?(pcm, event.sampleRate ?? 24_000)

        case "result":
            if let sessionID = event.sessionId { claudeSessionID = sessionID }
            lastCostUSD = event.costUsd

        case "error":
            appendError(event.message ?? "Unknown error")

        default:
            break
        }
    }

    private func closeTurn() {
        openAssistantIndex = nil
    }

    private func appendError(_ text: String) {
        openAssistantIndex = nil
        messages.append(Message(role: .error, text: text))
    }
}

private extension String {
    func trimmingLeadingNewlines() -> String {
        String(drop { $0.isNewline })
    }
}
