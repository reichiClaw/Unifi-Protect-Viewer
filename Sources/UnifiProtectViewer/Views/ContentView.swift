import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showingSettings = false
    @State private var editingView: CameraGridConfig?

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } detail: {
            detail
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
                .environmentObject(appState)
                .frame(width: 520, height: 460)
        }
        .sheet(item: $editingView) { view in
            ViewEditorView(view: view)
                .environmentObject(appState)
                .frame(width: 640, height: 560)
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: Binding(
                get: { appState.selectedViewID },
                set: { if let id = $0 { appState.selectView(id) } }
            )) {
                Section("Views") {
                    ForEach(appState.config.views) { view in
                        HStack {
                            Image(systemName: "square.grid.2x2")
                                .foregroundColor(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(view.name)
                                Text("\(view.cameraIDs.count) cameras · \(view.layout.label)")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                        .tag(view.id)
                        .contextMenu {
                            Button("Edit…") { editingView = view }
                            Button("Duplicate") { duplicate(view) }
                            Divider()
                            Button("Delete", role: .destructive) { appState.deleteView(view.id) }
                        }
                    }
                    .onMove { appState.moveViews(fromOffsets: $0, toOffset: $1) }
                }
            }
            .listStyle(.sidebar)

            Divider()
            sidebarFooter
        }
    }

    private var sidebarFooter: some View {
        VStack(spacing: 8) {
            HStack {
                Button {
                    let v = appState.addView(name: "View \(appState.config.views.count + 1)")
                    appState.selectView(v.id)
                    editingView = v
                } label: {
                    Label("Add View", systemImage: "plus")
                }
                Spacer()
                if let current = appState.currentView {
                    Button {
                        editingView = current
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .help("Edit current view")
                }
                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .help("Settings")
            }
            connectionStatusBar
        }
        .padding(10)
    }

    private var connectionStatusBar: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 9, height: 9)
            Text(statusText)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
            Spacer()
            if appState.connectionState == .connecting {
                ProgressView().controlSize(.mini)
            } else {
                Button {
                    appState.connect()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Connect / Refresh")
            }
        }
    }

    private var statusColor: Color {
        switch appState.connectionState {
        case .connected: return .green
        case .connecting: return .orange
        case .error: return .red
        case .disconnected: return .gray
        }
    }

    private var statusText: String {
        appState.statusMessage ?? appState.connectionState.rawValue.capitalized
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if appState.connectionState != .connected && appState.cameras.isEmpty {
            ConnectionPromptView(showSettings: { showingSettings = true })
        } else if let cam = appState.fullscreenCamera {
            FullscreenCameraView(camera: cam)
        } else {
            CameraGridView()
                .toolbar { gridToolbar }
        }
    }

    @ToolbarContentBuilder
    private var gridToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Text(appState.currentView?.name ?? "Cameras")
                .font(.headline)
        }
        ToolbarItemGroup {
            if let current = appState.currentView {
                Picker("Layout", selection: Binding(
                    get: { current.layout },
                    set: { newValue in
                        var updated = current
                        updated.layout = newValue
                        appState.updateView(updated)
                    }
                )) {
                    ForEach(GridLayout.allCases) { layout in
                        Text(layout.label).tag(layout)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 110)
            }
            Button {
                appState.previousView()
            } label: { Image(systemName: "chevron.left") }
                .help("Previous view (⌘←)")
            Button {
                appState.nextView()
            } label: { Image(systemName: "chevron.right") }
                .help("Next view (⌘→)")
        }
    }

    private func duplicate(_ view: CameraGridConfig) {
        var copy = view
        copy.id = UUID()
        copy.name = view.name + " Copy"
        appState.config.views.append(copy)
        appState.saveConfig()
    }
}
