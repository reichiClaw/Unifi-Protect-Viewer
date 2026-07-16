import SwiftUI
import AppKit

struct SettingsView: View {
    var body: some View {
        TabView {
            ConnectionSettingsTab()
                .tabItem { Label("Connection", systemImage: "network") }
            ManualStreamsTab()
                .tabItem { Label("Streams", systemImage: "dot.radiowaves.left.and.right") }
            ControlSettingsTab()
                .tabItem { Label("Stream Deck", systemImage: "rectangle.grid.3x2") }
            ReliabilitySettingsTab()
                .tabItem { Label("Reliability", systemImage: "cross.case") }
        }
        .padding(20)
        .frame(width: 520, height: 460)
    }
}

// MARK: - Reliability (24/7 control-room hardening)

private struct ReliabilitySettingsTab: View {
    @State private var autoRestart = LaunchAgentInstaller.isInstalled
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                Toggle("Automatically restart if it crashes or is killed", isOn: Binding(
                    get: { autoRestart },
                    set: { setAutoRestart($0) }
                ))
            } header: {
                Text("Auto-restart (recommended for 24/7 walls)")
            } footer: {
                Text("Installs a per-user macOS **LaunchAgent** that relaunches the app within seconds of any abnormal exit — a crash, a force-quit, or an out-of-memory (jetsam) kill — and starts it again at login. A normal **Quit** (⌘Q) is respected and will not relaunch.\n\nIf you move or rename the app after enabling this, toggle it off and on again so the restart points at the new location.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section {
                Button("Reveal log file in Finder") { revealLog() }
                LabeledContent("Log file", value: AppLog.shared.fileURL.path)
                    .font(.caption)
                    .textSelection(.enabled)
            } header: {
                Text("Diagnostics")
            } footer: {
                Text("The app logs CPU, memory and per-stream state, and records macOS memory-pressure warnings and crashes. If it still dies, also check `~/Library/Logs/DiagnosticReports/` for a crash or JetsamEvent report.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .alert("Auto-restart", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func setAutoRestart(_ on: Bool) {
        do {
            if on { try LaunchAgentInstaller.install() }
            else { try LaunchAgentInstaller.uninstall() }
            autoRestart = LaunchAgentInstaller.isInstalled
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            autoRestart = LaunchAgentInstaller.isInstalled
        }
    }

    private func revealLog() {
        NSWorkspace.shared.activateFileViewerSelecting([AppLog.shared.fileURL])
    }
}

// MARK: - Custom (non-UniFi) streams

private struct ManualStreamsTab: View {
    @EnvironmentObject private var appState: AppState
    @State private var newName = ""
    @State private var newURL = ""
    @State private var editing: ManualCamera?

    var body: some View {
        Form {
            Section {
                if appState.config.manualCameras.isEmpty {
                    Text("No custom streams yet. Add any RTSP/RTSPS/HTTP(S)/HLS stream below — it appears alongside your UniFi cameras and can be placed in any view.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                ForEach(appState.config.manualCameras) { cam in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(cam.name)
                            Text(cam.url)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Button {
                            editing = cam
                        } label: {
                            Image(systemName: "pencil")
                        }
                        .buttonStyle(.borderless)
                        .help("Edit")
                        Button(role: .destructive) {
                            appState.removeManualCamera(id: cam.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove")
                    }
                }
            } header: {
                Text("Custom streams")
            }

            Section {
                TextField("Name", text: $newName, prompt: Text("e.g. Warehouse RTSP"))
                TextField("Stream URL", text: $newURL, prompt: Text("rtsp://user:pass@host:554/stream"))
                Button {
                    appState.addManualCamera(name: newName, url: newURL)
                    newName = ""; newURL = ""
                } label: {
                    Label("Add stream", systemImage: "plus")
                }
                .disabled(newURL.trimmingCharacters(in: .whitespaces).isEmpty)
            } header: {
                Text("Add a stream")
            } footer: {
                Text("Any URL the player supports works (RTSP/RTSPS, HTTP(S), HLS `.m3u8`, …). Custom streams play the same URL in the grid and fullscreen (no substreams), and don't require a UniFi connection.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 460)
        .sheet(item: $editing) { cam in
            ManualStreamEditor(camera: cam) { updated in
                appState.updateManualCamera(updated)
            }
        }
    }
}

/// Edit an existing custom stream's name and URL.
private struct ManualStreamEditor: View {
    let camera: ManualCamera
    var onSave: (ManualCamera) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var url: String

    init(camera: ManualCamera, onSave: @escaping (ManualCamera) -> Void) {
        self.camera = camera
        self.onSave = onSave
        _name = State(initialValue: camera.name)
        _url = State(initialValue: camera.url)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit stream")
                .font(.headline)
            Form {
                TextField("Name", text: $name, prompt: Text("e.g. Warehouse RTSP"))
                TextField("Stream URL", text: $url, prompt: Text("rtsp://user:pass@host:554/stream"))
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    var updated = camera
                    updated.url = url.trimmingCharacters(in: .whitespacesAndNewlines)
                    let trimmedName = name.trimmingCharacters(in: .whitespaces)
                    updated.name = trimmedName.isEmpty ? updated.url : trimmedName
                    onSave(updated)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(url.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460, height: 240)
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
    @State private var autoConnect: Bool = true
    @State private var gridQuality: StreamQuality = .high
    @State private var fullscreenQuality: StreamQuality = .high
    @State private var mfaCode: String = ""
    @State private var cacheMs: Double = 1500
    @State private var hardwareDecoding: Bool = true

    var body: some View {
        Form {
            Section {
                TextField("Host / IP", text: $host, prompt: Text("192.168.1.1"))
                TextField("Username", text: $username, prompt: Text("local Protect account"))
                SecureField("Password", text: $password)
                TextField("2FA code (only if enabled)", text: $mfaCode, prompt: Text("optional"))
                Toggle("Connect automatically on launch", isOn: $autoConnect)
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
                Toggle("Hardware decoding (VideoToolbox)", isOn: $hardwareDecoding)
                VStack(alignment: .leading) {
                    Text("Buffer: \(Int(cacheMs)) ms")
                    Slider(value: $cacheMs, in: 300...5000, step: 100)
                }
            } header: {
                Text("Streaming")
            } footer: {
                Text("Leave RTSPS **off** — the encrypted stream uses the controller's self-signed certificate, which the video engine can't verify, so it fails (the app falls back to plain RTSP automatically). A higher **Fullscreen quality** gives a crisp single-camera view.\n\n**Hardware decoding** offloads video decode to the Mac's VideoToolbox engine, cutting CPU and memory use — keep it **on** for low-RAM machines. Streams that can't be hardware-decoded fall back to software automatically, and the app log records the actual decoder used per stream. Only turn this off if a stream shows decode artifacts.\n\n**Memory/CPU:** each grid tile decodes a live stream, and RAM use scales with resolution. On machines with 8 GB or many cameras, set **Grid quality = Low** (640×360) — this is by far the biggest way to cut memory and prevent freezes. A larger **Buffer** adds latency but is more resilient on a 24/7 wall (≈1500–2500 ms).\n\nQuality, buffer and decoding changes apply when a stream next (re)connects — reconnect or restart to apply them everywhere.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Behavior") {
                Toggle("Click fullscreen view to return to the grid", isOn: Binding(
                    get: { appState.config.tapFullscreenToExit },
                    set: { appState.config.tapFullscreenToExit = $0; appState.saveConfig() }
                ))
                Stepper(value: Binding(
                    get: { appState.config.ptzPresetCount },
                    set: { appState.config.ptzPresetCount = max(0, min(12, $0)); appState.saveConfig() }
                ), in: 0...12) {
                    Text("On-screen PTZ preset buttons: \(appState.config.ptzPresetCount)")
                }
            }

            Section {
                HStack {
                    Button("Save & Connect") { saveAndConnect() }
                        .buttonStyle(.borderedProminent)
                        .disabled(host.isEmpty || username.isEmpty)
                    Button("Save") { save() }
                    Button("Remove Saved Password", role: .destructive) {
                        appState.removeStoredPassword()
                        password = ""
                    }
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
        autoConnect = c.autoConnect
        gridQuality = c.gridQuality
        fullscreenQuality = c.fullscreenQuality
        cacheMs = Double(c.streamCacheMs)
        hardwareDecoding = c.hardwareDecoding
        password = appState.storedPassword ?? ""
    }

    private func makeSettings() -> ConnectionSettings {
        var c = ConnectionSettings()
        c.host = ProtectAPIClient.normalizeHost(host)
        c.username = username.trimmingCharacters(in: .whitespaces)
        c.useRTSPS = useRTSPS
        c.autoEnableRTSP = autoEnableRTSP
        c.autoConnect = autoConnect
        c.gridQuality = gridQuality
        c.fullscreenQuality = fullscreenQuality
        c.defaultQuality = gridQuality // keep legacy field in sync
        c.streamCacheMs = Int(cacheMs)
        c.hardwareDecoding = hardwareDecoding
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
    @State private var allowLAN: Bool = false

    var body: some View {
        Form {
            Section {
                Toggle("Enable control server", isOn: $enabled)
                TextField("Port", text: $port)
                Toggle("Allow control from other computers (LAN)", isOn: $allowLAN)
                SecureField(allowLAN ? "Auth token (required)" : "Auth token (optional)", text: $token)
                Button("Generate secure token") { token = ControlServerSettings.makeToken() }
            } header: {
                Text("Control Server")
            } footer: {
                Text("By default the server listens only on this Mac (127.0.0.1). LAN access is opt-in and always requires a token. Enter the same token in every Stream Deck button.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Endpoint") {
                LabeledContent("Binding", value: allowLAN ? "All LAN interfaces" : "This Mac only")
                LabeledContent("Base URL", value: allowLAN ? "http://<this-mac-ip>:\(port)" : "http://127.0.0.1:\(port)")
                LabeledContent("WebSocket", value: allowLAN ? "ws://<this-mac-ip>:\(port)/ws" : "ws://127.0.0.1:\(port)/ws")
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
        allowLAN = appState.config.control.allowLAN
    }

    private func apply() {
        appState.config.control.enabled = enabled
        appState.config.control.port = UInt16(port) ?? 8723
        appState.config.control.allowLAN = allowLAN
        appState.config.control.token = allowLAN && token.isEmpty
            ? ControlServerSettings.makeToken()
            : token
        token = appState.config.control.token
        appState.saveConfig()
        appState.restartControlServer()
    }
}
