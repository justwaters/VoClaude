import Foundation
import Testing
@testable import VoClaude

@MainActor
struct SessionStoreTests {
    private func makeStore() -> SessionStore {
        let defaults = UserDefaults(suiteName: "VoClaudeTests-\(UUID())")!
        return SessionStore(defaults: defaults)
    }

    private let mac = DiscoveredDaemon(
        id: "VoClaude on Mac",
        host: "10.0.0.5:8000",
        mdnsHost: "voclaude-mac.local:8000",
        version: "0.1.2"
    )

    @Test func migratesSessionsPairedByLocalName() {
        let store = makeStore()
        store.upsert(Session(name: "App", host: "voclaude-mac.local:8000", repoAlias: "app"))
        store.refreshHosts(from: [mac])
        #expect(store.sessions[0].host == "10.0.0.5:8000")
        #expect(store.sessions[0].daemonID == "VoClaude on Mac")
    }

    @Test func followsTheDaemonToANewAddress() {
        let store = makeStore()
        store.upsert(Session(name: "App", host: "10.0.0.5:8000", repoAlias: "app", daemonID: mac.id))
        let moved = DiscoveredDaemon(id: mac.id, host: "10.0.0.9:8000", mdnsHost: mac.mdnsHost, version: nil)
        store.refreshHosts(from: [moved])
        #expect(store.sessions[0].host == "10.0.0.9:8000")
    }

    @Test func leavesHandAddedHostsAlone() {
        let store = makeStore()
        store.upsert(Session(name: "Remote", host: "100.115.55.24:8000", repoAlias: "app"))
        store.refreshHosts(from: [mac])
        #expect(store.sessions[0].host == "100.115.55.24:8000")
        #expect(store.sessions[0].daemonID == nil)
    }
}
