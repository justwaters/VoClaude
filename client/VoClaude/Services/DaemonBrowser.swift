import Foundation
import Network
import Observation

/// A voclaude daemon found on the local network via Bonjour (`_voclaude._tcp`).
struct DiscoveredDaemon: Identifiable, Hashable, Sendable {
    /// Bonjour instance name, e.g. "VoClaude on JDs-MacBook-Pro".
    let id: String
    /// `voclaude-jds-macbook-pro.local:8000`
    let host: String
    let version: String?

    var displayName: String {
        id.replacingOccurrences(of: "VoClaude on ", with: "")
    }
}

/// A repo watched by a daemon, as returned by `GET /sessions`.
struct RemoteRepo: Decodable, Identifiable, Hashable, Sendable {
    let alias: String
    let displayName: String
    var id: String { alias }
}

/// Browses for daemons while the app is in the foreground.
@MainActor
@Observable
final class DaemonBrowser {
    private(set) var daemons: [DiscoveredDaemon] = []
    private(set) var error: String?

    @ObservationIgnored private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: "_voclaude._tcp", domain: nil),
            using: .tcp
        )
        browser.browseResultsChangedHandler = { @Sendable [weak self] results, _ in
            let found = results.compactMap(Self.daemon(from:)).sorted { $0.id < $1.id }
            Task { @MainActor in self?.daemons = found }
        }
        browser.stateUpdateHandler = { @Sendable [weak self] state in
            let message: String? = switch state {
            case .failed(let error), .waiting(let error): Self.describe(error)
            default: nil
            }
            Task { @MainActor in self?.error = message }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
        daemons = []
    }

    private nonisolated static func daemon(from result: NWBrowser.Result) -> DiscoveredDaemon? {
        guard case .service(let name, _, _, _) = result.endpoint else { return nil }
        var txt: [String: String] = [:]
        if case .bonjour(let record) = result.metadata {
            txt = record.dictionary
        }
        let port = txt["port"] ?? "8000"
        // Prefer the daemon's own mDNS name: it survives DHCP address changes.
        guard let host = txt["host"] ?? txt["ips"]?.split(separator: ",").first.map(String.init) else {
            return nil
        }
        return DiscoveredDaemon(id: name, host: "\(host):\(port)", version: txt["version"])
    }

    private nonisolated static func describe(_ error: NWError) -> String {
        if case .dns(let code) = error, code == -65570 {  // kDNSServiceErr_PolicyDenied
            return "Allow Local Network access in Settings to find daemons."
        }
        return error.localizedDescription
    }
}

enum DaemonAPI {
    enum APIError: LocalizedError {
        case badHost
        case unauthorized
        case http(Int)
        case unreachable(String)

        var errorDescription: String? {
            switch self {
            case .badHost: "Invalid daemon address."
            case .unauthorized: "Wrong token. Run `voclaude token` on the daemon's machine."
            case .http(let code): "The daemon returned HTTP \(code)."
            case .unreachable(let host): unreachableMessage(host)
            }
        }
    }

    /// iOS reports blocked or unroutable local connections as "offline" or "timed out".
    /// Say what actually needs checking.
    static func unreachableMessage(_ host: String) -> String {
        "Can't reach \(host). Make sure this device is on the same Wi-Fi as the computer, "
            + "`voclaude serve` is running, and Local Network access is on "
            + "(Settings → Privacy & Security → Local Network → VoClaude)."
    }

    static func isUnreachable(_ error: Error) -> Bool {
        guard let error = error as? URLError else { return false }
        return [.notConnectedToInternet, .timedOut, .cannotConnectToHost, .cannotFindHost,
                .networkConnectionLost, .dnsLookupFailed].contains(error.code)
    }

    /// Repos the daemon watches (`voclaude watch`).
    static func repos(host: String, token: String) async throws -> [RemoteRepo] {
        guard let url = URL(string: "http://\(host)/sessions") else { throw APIError.badHost }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch where isUnreachable(error) {
            throw APIError.unreachable(host)
        }
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200: break
        case 401: throw APIError.unauthorized
        case let code: throw APIError.http(code)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode([RemoteRepo].self, from: data)
    }
}
