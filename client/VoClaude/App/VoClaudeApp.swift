import SwiftUI

@main
struct VoClaudeApp: App {
    @State private var store = SessionStore()
    @State private var recorder: AudioRecorder
    @State private var connections: WebSocketManager
    @State private var call: CallController
    @State private var browser = DaemonBrowser()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let recorder = AudioRecorder()
        let connections = WebSocketManager(player: AudioPlayer())
        _recorder = State(initialValue: recorder)
        _connections = State(initialValue: connections)
        _call = State(initialValue: CallController(connections: connections, recorder: recorder))
    }

    var body: some Scene {
        WindowGroup {
            MainView()
                .environment(store)
                .environment(recorder)
                .environment(connections)
                .environment(call)
                .environment(browser)
                .onChange(of: scenePhase, initial: true) { _, phase in
                    // Browse only while visible; a call keeps running in the background regardless.
                    if phase == .active { browser.start() } else if phase == .background { browser.stop() }
                }
        }
        #if os(macOS)
        .defaultSize(width: 960, height: 680)
        #endif
    }
}
