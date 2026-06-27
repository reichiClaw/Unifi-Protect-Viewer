import SwiftUI

/// Editor for a single configurable grid view: name, layout, quality, and the
/// ordered set of cameras it contains.
struct ViewEditorView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var draft: CameraGridConfig
    private let originalID: UUID

    init(view: CameraGridConfig) {
        _draft = State(initialValue: view)
        originalID = view.id
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                includedColumn
                Divider()
                availableColumn
            }
            Divider()
            footer
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 12) {
            TextField("View name", text: $draft.name)
                .textFieldStyle(.roundedBorder)
                .font(.title3)

            HStack {
                Picker("Layout", selection: $draft.layout) {
                    ForEach(GridLayout.allCases) { Text($0.label).tag($0) }
                }
                .frame(width: 180)

                Picker("Quality", selection: $draft.quality) {
                    Text("Grid default (\(appState.config.connection.gridQuality.label))")
                        .tag(StreamQuality?.none)
                    ForEach(StreamQuality.allCases) { q in
                        Text(q.label).tag(StreamQuality?.some(q))
                    }
                }
                .frame(width: 220)
                Spacer()
            }
        }
        .padding()
    }

    // MARK: Included cameras (ordered)

    private var includedColumn: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("In this view (\(draft.cameraIDs.count))")
                .font(.headline)
                .padding(.horizontal)
                .padding(.top, 8)
            List {
                ForEach(draft.cameraIDs, id: \.self) { id in
                    HStack {
                        Image(systemName: "line.3.horizontal")
                            .foregroundColor(.secondary)
                        Text(appState.camera(for: id)?.displayName ?? id)
                        Spacer()
                        Button {
                            draft.cameraIDs.removeAll { $0 == id }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .onMove { draft.cameraIDs.move(fromOffsets: $0, toOffset: $1) }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Available cameras

    private var availableColumn: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Available cameras")
                    .font(.headline)
                Spacer()
                Button("Add all") {
                    for cam in appState.cameras where !draft.cameraIDs.contains(cam.id) {
                        draft.cameraIDs.append(cam.id)
                    }
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal)
            .padding(.top, 8)

            List {
                ForEach(appState.cameras) { cam in
                    let included = draft.cameraIDs.contains(cam.id)
                    HStack {
                        Circle()
                            .fill(cam.isOnline ? Color.green : Color.red)
                            .frame(width: 8, height: 8)
                        Text(cam.displayName)
                        Spacer()
                        Button {
                            if included {
                                draft.cameraIDs.removeAll { $0 == cam.id }
                            } else {
                                draft.cameraIDs.append(cam.id)
                            }
                        } label: {
                            Image(systemName: included ? "checkmark.circle.fill" : "plus.circle")
                                .foregroundColor(included ? .green : .accentColor)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if isExisting {
                Button("Delete View", role: .destructive) {
                    appState.deleteView(originalID)
                    dismiss()
                }
            }
            Spacer()
            Button("Cancel") { dismiss() }
            Button("Save") {
                if isExisting {
                    appState.updateView(draft)
                } else {
                    appState.config.views.append(draft)
                    appState.saveConfig()
                }
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding()
    }

    private var isExisting: Bool {
        appState.config.views.contains { $0.id == originalID }
    }
}
