import SwiftUI
import AppKit
import AitvarasAgents

struct ForgeConnectionsSection: View {
    @Environment(AppModel.self) private var model
    @State private var statuses: [ForgeKind: ForgeAuthStatus] = [:]
    @State private var error: String?
    private var enabled: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["AITVARAS_DISABLE_EXTERNAL_INTEGRATIONS"] != "1" && env["AITVARAS_UI_TEST_MODE"] != "1"
    }
    var body: some View {
        Section("Git hosts") {
            ForEach(ForgeKind.allCases, id: \.self) { kind in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("\(kind.title) (\(kind.executableName))")
                        Spacer()
                        if let status = statuses[kind] {
                            Text(!status.installed ? "Not installed" : status.signedInHosts.isEmpty ? "Installed · signed out" : "Signed in for " + status.signedInHosts.joined(separator: ", "))
                                .font(.caption).foregroundStyle(.secondary)
                        } else { Text(enabled ? "Not checked" : "External integrations disabled").font(.caption).foregroundStyle(.secondary) }
                    }
                    if let status = statuses[kind] {
                        if !status.installed {
                            Text("Install \(kind.title) CLI (\(kind.executableName)) to see \(kind.requestName)s").font(.caption).foregroundStyle(.secondary)
                        } else {
                            ForEach(Array(Set(status.knownHosts + [kind.publicHost])).sorted(), id: \.self) { host in
                                if !status.isSignedIn(host: host) { ForgeSignInButton(kind: kind, host: host) { await refresh() } }
                            }
                        }
                    }
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.secondary) }
            Button("Refresh Git hosts") { Task { await refresh() } }.disabled(!enabled)
        }.task(id: model.chatModel != nil) { await refresh() }
    }
    private func refresh() async {
        guard enabled, let actions = model.chatModel?.forgeActions else { return }
        for kind in ForgeKind.allCases {
            do { statuses[kind] = try await actions.authStatus(kind: kind, host: kind.publicHost); error = nil }
            catch let failure { self.error = (failure as? ForgeError)?.message ?? "Could not check Git hosts." }
        }
    }
}

struct ForgeSignInButton: View {
    @Environment(AppModel.self) private var model
    let kind: ForgeKind
    let host: String
    var completed: (() async -> Void)? = nil
    @State private var task: Task<Void, Never>?
    @State private var error: String?
    @State private var deviceCode: String?
    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Button("Sign in to \(host)…") {
                    guard task == nil, let actions = model.chatModel?.forgeActions else { return }
                    task = Task {
                        defer { task = nil; deviceCode = nil }
                        do {
                            try await actions.signIn(kind: kind, host: host, confirmed: true, onDeviceCode: { code in
                                await MainActor.run { deviceCode = code }
                            }) { url in
                                await MainActor.run { if (try? ProviderSignIn.validate(url)) != nil { NSWorkspace.shared.open(url) } }
                            }
                            error = nil; await completed?()
                        } catch { self.error = (error as? ForgeError)?.message ?? "Sign-in did not complete." }
                    }
                }.disabled(task != nil)
                if task != nil { Button("Cancel") { task?.cancel() } }
            }
            if let deviceCode { Text("Enter code in browser: " + deviceCode).font(.callout.monospaced()).textSelection(.enabled) }
            if let error { Text(error).font(.caption).foregroundStyle(.secondary) }
        }.onDisappear { task?.cancel() }
    }
}
