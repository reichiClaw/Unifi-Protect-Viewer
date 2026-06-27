import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            ConnectionSettingsTab()
                .tabItem { Label("Connection", systemImage: "network") }
            ControlSettingsTab()
                .tabItem { Label("Stream Deck", systemImage: "rectangle.grid.3x2") }
        }
        .padding(20)
        .frame(width: 520, height: 460)
    }
}

// MARK: - Connection

private struct ConnectionSettingsTab: View {
    @EnvironmentObject private var appState: AppState

    @State private var host: String = ""
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var useRTSPS: Bool = false
    @State private var autoEnableRTSP: Bool = true
    @State private var gridQuality: StreamQuality = .high
    @State private var fullscreenQuality: StreamQuality = .high
    @State private var mfaCode: String = ""
    @State private var cacheMs: Double = 1500

    var body: some View {
        Form {
            Section {
                TextField("Host / IP", text: $host, prompt: Text("192.168.1.1"))
                TextField("Username", text: $username, prompt: Text("local Protect account"))
                SecureField("Password", text: $password)
                TextField("2FA code (only if enabled)", text: $mfaCode, prompt: Text("optional"))
            } header: {
                Text("Controller")
            } footer: {
                Text("Use a *local* UniFi Protect account (not a Ubiquiti cloud login). Read-only accounts work for viewing; enabling RTSP automatically requires admin. If the account has two-factor auth, enter a current code above just before connecting.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section {
                Picker("Grid quality", selection: $gridQuality) {
                    ForEach(StreamQuality.allCases) { q in Text(q.label).tag(q) }
                }
                Picker("Fullscreen quality", selection: $fullscreenQuality) {
                    ForEach(StreamQuality.allCases) { q in Text(q.label).tag(q) }
                }
                Toggle("Use RTSPS (encrypted, port 7441)", isOn: $useRTSPS)
                Toggle("Auto-enable RTSP on cameras", isOn: $autoEnableRTSP)
                VStack(alignment: .leading) {
                    Text("Buffer: \(Int(cacheMs)) ms")
                    Slider(value: $cacheMs, in: 300...5000, step: 100)
                }
            } header: {
                Text("Streaming")
            } footer: {
                Text("Leave RTSPS **off** — the encrypted stream uses the controller's self-signed certificate, which the video engine can't verify, so it fails (the app falls back to plain RTSP automatically). Use a lower **Grid quality** (Low/Medium) for many cameras to reduce CPU/bandwidth, and a higher **Fullscreen quality** for the single-camera view. A larger **Buffer** adds latency but makes playback much more resilient on a 24/7 wall (≈1500–2500 ms recommended).")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section {
                HStack {
                    Button("Save & Connect") { saveAndConnect() }
                        .buttonStyle(.borderedProminent)
                        .disabled(host.isEmpty || username.isEmpty)
                    Button("Save") { save() }
                    Spacer()
                    statusLabel
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: loadCurrent)
    }

    private var statusLabel: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(appState.connectionState == .connected ? .green :
                        appState.connectionState == .error ? .red : .gray)
                .frame(width: 8, height: 8)
            Text(appState.statusMessage ?? appState.connectionState.rawValue.capitalized)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
    }

    private func loadCurrent() {
        let c = appState.config.connection
        host = c.host
        username = c.username
        useRTSPS = c.useRTSPS
        autoEnableRTSP = c.autoEnableRTSP
        gridQuality = c.gridQuality
        fullscreenQuality = c.fullscreenQuality
        cacheMs = Double(c.streamCacheMs)
        password = appState.storedPassword ?? ""
    }

    private func makeSettings() -> ConnectionSettings {
        var c = ConnectionSettings()
        c.host = ProtectAPIClient.normalizeHost(host)
        c.username = username.trimmingCharacters(in: .whitespaces)
        c.useRTSPS = useRTSPS
        c.autoEnableRTSP = autoEnableRTSP
        c.gridQuality = gridQuality
        c.fullscreenQuality = fullscreenQuality
        c.defaultQuality = gridQuality // keep legacy field in sync
        c.streamCacheMs = Int(cacheMs)
        return c
    }

    private func save() {
        appState.updateConnection(makeSettings(), password: password)
    }

    private func saveAndConnect() {
        save()
        appState.mfaCode = mfaCode.trimmingCharacters(in: .whitespaces)
        appState.connect()
    }
}

// MARK: - Control server / Stream Deck

private struct ControlSettingsTab: View {
    @EnvironmentObject private var appState: AppState

    @State private var enabled: Bool = true
    @State private var port: String = "8723"
    @State private var token: String = ""

    var body: some View {
        Form {
            Section {
                Toggle("Enable control server", isOn: $enabled)
                TextField("Port", text: $port)
                TextField("Auth token (optional)", text: $token)
            } header: {
                Text("Local Control Server")
            } footer: {
                Text("The Stream Deck plugin connects to this server to switch views and pop cameras fullscreen. Leave the token blank for an unauthenticated local-only server, or set one and enter the same value in the plugin.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Endpoint") {
                LabeledContent("Base URL", value: "http://127.0.0.1:\(port)")
                LabeledContent("WebSocket", value: "ws://127.0.0.1:\(port)/ws")
                LabeledContent("Status", value: appState.config.control.enabled ? "Running" : "Stopped")
            }

            Section {
                Button("Apply") { apply() }
                    .buttonStyle(.borderedProminent)
            } footer: {
                Text("Endpoints: GET /api/state · POST /api/select-view · /api/next-view · /api/prev-view · /api/fullscreen · /api/toggle-fullscreen · /api/exit-fullscreen")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: load)
    }

    private func load() {
        enabled = appState.config.control.enabled
        port = String(appState.config.control.port)
        token = appState.config.control.token
    }

    private func apply() {
        appState.config.control.enabled = enabled
        appState.config.control.port = UInt16(port) ?? 8723
        appState.config.control.token = token
        appState.saveConfig()
        appState.restartControlServer()
    }
}
