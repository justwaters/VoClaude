import Foundation

struct Message: Identifiable, Hashable, Sendable {
    enum Role: Hashable, Sendable {
        case user
        case assistant
        case tool(name: String)
        case error
        case system
    }

    let id = UUID()
    let role: Role
    var text: String
    let timestamp = Date()
}

/// Wire format for events sent by voclaude-daemon (see daemon/main.py).
struct ServerEvent: Decodable, Sendable {
    let type: String
    var content: String?
    var data: String?
    var sampleRate: Double?
    var state: String?
    var name: String?
    var summary: String?
    var message: String?
    var sessionId: String?
    var displayName: String?
    var isError: Bool?
    var costUsd: Double?
    var tts: Bool?
    var stt: Bool?
    var voices: [VoiceOption]?
    var defaultVoice: String?
}

/// A speech voice the daemon offers, e.g. `af_heart` / "Heart (American, female)".
struct VoiceOption: Decodable, Hashable, Identifiable, Sendable {
    let id: String
    let name: String
}
