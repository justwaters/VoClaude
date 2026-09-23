import SwiftUI

@main
struct VoClaudeApp: App {
    @State private var store = SessionStore()
    @State private var recorder = AudioRecorder()
    @State private var connections: WebSocketManager

    init() {
        _connections = State(initialValue: WebSocketManager(player: AudioPlayer()))
    }

    var body: some Scene {
        WindowGroup {
            MainView()
                .environment(store)
                .environment(recorder)
                .environment(connections)
        }
        #if os(macOS)
        .defaultSize(width: 960, height: 680)
        #endif
    }
}
