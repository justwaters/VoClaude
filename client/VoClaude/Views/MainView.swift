import SwiftUI

struct MainView: View {
    @Environment(SessionStore.self) private var store
    @Environment(WebSocketManager.self) private var connections

    @State private var editor: EditorTarget?
    @AppStorage("onDeviceTranscription") private var onDeviceTranscription = false

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            List(selection: $store.selectedID) {
                ForEach(store.sessions) { session in
                    SessionRow(session: session, connection: connections.connections[session.id])
                        .tag(session.id)
                        .contextMenu {
                            Button("Edit…", systemImage: "pencil") { editor = .edit(session) }
                            Button("Delete", systemImage: "trash", role: .destructive) { delete([session.id]) }
                        }
                }
                .onMove(perform: store.move)
                .onDelete { offsets in delete(offsets.map { store.sessions[$0].id }) }
            }
            .navigationTitle("VoClaude")
            #if os(macOS)
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
            #endif
            .toolbar {
                ToolbarItem {
                    Button("Add Session", systemImage: "plus") { editor = .new }
                }
                ToolbarItem {
                    Menu("Settings", systemImage: "gearshape") {
                        Toggle("Transcribe on device", isOn: $onDeviceTranscription)
                    }
                }
            }
            .overlay {
                if store.sessions.isEmpty {
                    ContentUnavailableView {
                        Label("No Sessions", systemImage: "waveform")
                    } description: {
                        Text("Add a daemon host and repo alias to start talking to Claude.")
                    } actions: {
                        Button("Add Session") { editor = .new }
                    }
                }
            }
        } detail: {
            if let session = store.selected {
                SessionDetailView(session: session, onEdit: { editor = .edit(session) })
                    .id(session.id)
            } else {
                ContentUnavailableView("Select a Session", systemImage: "sidebar.left")
            }
        }
        .sheet(item: $editor) { target in
            switch target {
            case .new:
                SessionEditorView(session: nil, token: nil)
            case .edit(let session):
                SessionEditorView(session: session, token: store.token(for: session.host))
            }
        }
    }

    private func delete(_ ids: [Session.ID]) {
        ids.forEach(connections.remove)
        store.delete(ids)
    }
}

private enum EditorTarget: Identifiable {
    case new
    case edit(Session)

    var id: String {
        switch self {
        case .new: "new"
        case .edit(let session): session.id.uuidString
        }
    }
}

private struct SessionRow: View {
    let session: Session
    let connection: SessionConnection?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.name)
                Text("\(session.repoAlias) · \(session.host)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if connection?.isBusy == true {
                ProgressView().controlSize(.small)
            } else {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                    .accessibilityLabel(statusLabel)
            }
        }
    }

    private var statusColor: Color {
        switch connection?.state {
        case .connected: .green
        case .connecting: .yellow
        case .failed: .red
        case .disconnected, nil: .gray.opacity(0.4)
        }
    }

    private var statusLabel: String {
        switch connection?.state {
        case .connected: "Connected"
        case .connecting: "Connecting"
        case .failed: "Connection failed"
        case .disconnected, nil: "Not connected"
        }
    }
}

#Preview {
    MainView()
        .environment(SessionStore())
        .environment(AudioRecorder())
        .environment(WebSocketManager(player: AudioPlayer()))
}
