import SwiftUI

struct SessionEditorView: View {
    @Environment(SessionStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var draft: Session
    @State private var token: String
    private let isNew: Bool

    init(session: Session?, token: String?) {
        _draft = State(initialValue: session ?? Session(name: "", host: "", repoAlias: ""))
        _token = State(initialValue: token ?? "")
        isNew = session == nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Session") {
                    TextField("Name", text: $draft.name, prompt: Text("Repo A"))
                    TextField("Repo alias", text: $draft.repoAlias, prompt: Text("repo_a"))
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                }
                Section {
                    TextField("Host", text: $draft.host, prompt: Text("192.168.1.100:8000"))
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                    SecureField("Token", text: $token, prompt: Text("From the daemon's startup log"))
                } header: {
                    Text("Daemon")
                } footer: {
                    if let url = draft.webSocketURL, !draft.repoAlias.isEmpty {
                        Text(url.absoluteString).textSelection(.enabled)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(isNew ? "New Session" : "Edit Session")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(!isValid)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 320)
        #endif
    }

    private var isValid: Bool {
        !draft.repoAlias.trimmingCharacters(in: .whitespaces).isEmpty && draft.webSocketURL != nil
    }

    private func save() {
        draft.repoAlias = draft.repoAlias.trimmingCharacters(in: .whitespaces)
        draft.host = draft.host.trimmingCharacters(in: .whitespaces)
        if draft.name.trimmingCharacters(in: .whitespaces).isEmpty {
            draft.name = draft.repoAlias
        }
        store.setToken(token.trimmingCharacters(in: .whitespacesAndNewlines), for: draft.host)
        store.upsert(draft)
        store.selectedID = draft.id
        dismiss()
    }
}
