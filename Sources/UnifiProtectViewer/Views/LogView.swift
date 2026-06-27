import SwiftUI
import AppKit

/// In-app log viewer. Shows live log entries with filtering, copy, clear, and
/// "reveal log file" actions.
struct LogView: View {
    @ObservedObject private var log = AppLog.shared
    @State private var minLevel: AppLog.Level = .debug
    @State private var autoScroll = true

    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private var filtered: [AppLog.Entry] {
        log.entries.filter { $0.level.rank >= minLevel.rank }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            logList
        }
        .frame(minWidth: 560, minHeight: 360)
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Picker("Level", selection: $minLevel) {
                ForEach(AppLog.Level.allCases, id: \.self) { level in
                    Text(level.rawValue).tag(level)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 140)

            Toggle("Auto-scroll", isOn: $autoScroll)
                .toggleStyle(.checkbox)

            Spacer()

            Text("\(filtered.count) entries")
                .font(.caption)
                .foregroundColor(.secondary)

            Button {
                copyAll()
            } label: { Label("Copy", systemImage: "doc.on.doc") }

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([log.fileURL])
            } label: { Label("Reveal File", systemImage: "folder") }

            Button(role: .destructive) {
                log.clear()
            } label: { Label("Clear", systemImage: "trash") }
        }
        .padding(8)
    }

    private var logList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(filtered) { entry in
                        HStack(alignment: .top, spacing: 8) {
                            Text(formatter.string(from: entry.date))
                                .foregroundColor(.secondary)
                            Text(entry.level.rawValue)
                                .foregroundColor(color(for: entry.level))
                                .frame(width: 48, alignment: .leading)
                            Text(entry.message)
                                .foregroundColor(.primary)
                                .textSelection(.enabled)
                            Spacer(minLength: 0)
                        }
                        .font(.system(.caption, design: .monospaced))
                        .id(entry.id)
                    }
                }
                .padding(8)
            }
            .onChange(of: log.entries.count) { _ in
                if autoScroll, let last = filtered.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func color(for level: AppLog.Level) -> Color {
        switch level {
        case .debug: return .secondary
        case .info: return .blue
        case .warn: return .orange
        case .error: return .red
        }
    }

    private func copyAll() {
        let text = filtered.map { $0.formatted(fullFormatter) }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private let fullFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()
}
