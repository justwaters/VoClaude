import Foundation
import Observation
import Security

/// Persists the session list (UserDefaults) and per-host daemon tokens (Keychain).
@MainActor
@Observable
final class SessionStore {
    private(set) var sessions: [Session]
    var selectedID: Session.ID?

    @ObservationIgnored private let defaults: UserDefaults
    private static let sessionsKey = "sessions.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.sessionsKey),
           let saved = try? JSONDecoder().decode([Session].self, from: data) {
            sessions = saved
        } else {
            sessions = []  // discovered daemons appear under Nearby
        }
        selectedID = sessions.first?.id
    }

    var selected: Session? {
        sessions.first { $0.id == selectedID }
    }

    func upsert(_ session: Session) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.append(session)
        }
        save()
    }

    func delete(_ ids: some Sequence<Session.ID>) {
        let ids = Set(ids)
        sessions.removeAll { ids.contains($0.id) }
        if let selectedID, ids.contains(selectedID) {
            self.selectedID = sessions.first?.id
        }
        save()
    }

    func move(from source: IndexSet, to destination: Int) {
        sessions.move(fromOffsets: source, toOffset: destination)
        save()
    }

    /// Point sessions at the current address of daemons seen on the network.
    func refreshHosts(from daemons: [DiscoveredDaemon]) {
        var changed = false
        for index in sessions.indices {
            let session = sessions[index]
            guard let daemon = daemons.first(where: {
                $0.id == session.daemonID || (session.daemonID == nil && $0.mdnsHost == session.host)
            }) else { continue }
            if session.daemonID == nil, let legacy = token(for: session.host) {
                setToken(legacy, for: daemon.id)  // token was saved under the .local host
            }
            if session.host != daemon.host || session.daemonID != daemon.id {
                sessions[index].host = daemon.host
                sessions[index].daemonID = daemon.id
                changed = true
            }
        }
        if changed { save() }
    }

    private func save() {
        do {
            defaults.set(try JSONEncoder().encode(sessions), forKey: Self.sessionsKey)
        } catch {
            assertionFailure("Failed to encode sessions: \(error)")
        }
    }

    // MARK: Tokens

    func token(for host: String) -> String? {
        Keychain.read(account: Self.normalized(host))
    }

    func setToken(_ token: String, for host: String) {
        let account = Self.normalized(host)
        if token.isEmpty {
            Keychain.delete(account: account)
        } else {
            Keychain.write(token, account: account)
        }
    }

    private static func normalized(_ host: String) -> String {
        host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

private enum Keychain {
    static let service = "VoClaude.daemon-token"

    static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
        }
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
