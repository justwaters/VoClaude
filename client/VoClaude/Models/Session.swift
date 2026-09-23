import Foundation

/// A daemon host + repo alias pair the user can talk to.
struct Session: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var name: String
    /// Host and port of the daemon, e.g. `192.168.1.100:8000`. A `ws://` or `wss://` prefix is optional.
    var host: String
    /// Repo alias configured in the daemon's config.json, e.g. `repo_a`.
    var repoAlias: String
    /// Kokoro voice ID (e.g. `bf_emma`); nil uses the daemon's default voice.
    var voice: String? = nil

    /// `ws://192.168.1.100:8000/ws/session/repo_a`
    var webSocketURL: URL? {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.contains("://") ? trimmed : "ws://\(trimmed)"
        guard var components = URLComponents(string: base), components.host != nil else { return nil }
        let prefix = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = "\(prefix)/ws/session/\(repoAlias)"
        return components.url
    }

}
