import SwiftUI

/// Pair with a discovered daemon: enter its token once, then pick which watched repos to add.
struct DaemonConnectView: View {
    let daemon: DiscoveredDaemon

    @Environment(SessionStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var token = ""
    @State private var repos: [RemoteRepo] = []
    @State private var selected: Set<RemoteRepo.ID> = []
    @State private var isLoading = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Token", text: $token, prompt: Text("Run `voclaude token` on \(daemon.displayName)"))
                        .onSubmit { Task { await load() } }
                    Button {
                        Task { await load() }
                    } label: {
                        HStack {
                            Text(repos.isEmpty ? "Connect" : "Refresh Repos")
                            if isLoading {
                                Spacer()
                                ProgressView().controlSize(.small)
                            }
                        }
                    }
                    .disabled(token.isEmpty || isLoading)
                } header: {
                    Text(daemon.displayName)
                } footer: {
                    if let error {
                        Text(error).foregroundStyle(.red)
                    } else {
                        Text(daemon.host + (daemon.version.map { " · v\($0)" } ?? ""))
                    }
                }

                if !repos.isEmpty {
                    Section {
                        ForEach(repos) { repo in
                            let added = isAdded(repo)
                            Toggle(isOn: binding(for: repo)) {
                                VStack(alignment: .leading) {
                                    Text(repo.displayName)
                                    Text(added ? "\(repo.alias) · already added" : repo.alias)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .disabled(added)
                        }
                    } header: {
                        Text("Watched Repos")
                    } footer: {
                        Text("Add more with `voclaude watch` inside a repo, then refresh.")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Connect")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add", action: add).disabled(selected.isEmpty)
                }
            }
            .task {
                if let saved = store.token(for: daemon.host) {
                    token = saved
                    await load()
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 360)
        #endif
    }

    private func isAdded(_ repo: RemoteRepo) -> Bool {
        store.sessions.contains { $0.host == daemon.host && $0.repoAlias == repo.alias }
    }

    private func binding(for repo: RemoteRepo) -> Binding<Bool> {
        Binding {
            selected.contains(repo.id)
        } set: { isOn in
            if isOn { selected.insert(repo.id) } else { selected.remove(repo.id) }
        }
    }

    private func load() async {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            repos = try await DaemonAPI.repos(host: daemon.host, token: token)
            selected = Set(repos.filter { !isAdded($0) }.map(\.id))
            error = repos.isEmpty ? "No repos watched yet. Run `voclaude watch` inside a repo." : nil
            store.setToken(token, for: daemon.host)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func add() {
        var firstAdded: Session.ID?
        for repo in repos where selected.contains(repo.id) && !isAdded(repo) {
            let session = Session(name: repo.displayName, host: daemon.host, repoAlias: repo.alias)
            store.upsert(session)
            firstAdded = firstAdded ?? session.id
        }
        if let firstAdded { store.selectedID = firstAdded }
        dismiss()
    }
}
