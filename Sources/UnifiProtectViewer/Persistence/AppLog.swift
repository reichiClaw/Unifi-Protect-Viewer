import Foundation
import Combine
import Darwin

/// Lightweight app-wide logger that keeps recent entries in memory (for the
/// in-app log viewer) and appends everything to a file on disk.
///
/// Thread-safe: `log(_:level:)` may be called from any thread/actor. File
/// writes happen on a serial queue; the published `entries` array is updated on
/// the main thread for SwiftUI.
final class AppLog: ObservableObject {
    static let shared = AppLog()

    enum Level: String, CaseIterable {
        case debug = "DEBUG"
        case info = "INFO"
        case warn = "WARN"
        case error = "ERROR"

        var rank: Int {
            switch self {
            case .debug: return 0
            case .info: return 1
            case .warn: return 2
            case .error: return 3
            }
        }
    }

    struct Entry: Identifiable {
        let id = UUID()
        let date: Date
        let level: Level
        let message: String

        func formatted(_ formatter: DateFormatter) -> String {
            "\(formatter.string(from: date)) [\(level.rawValue)] \(message)"
        }
    }

    @Published private(set) var entries: [Entry] = []

    let fileURL: URL
    let crashFileURL: URL
    private let queue = DispatchQueue(label: "com.unifiprotectviewer.applog")
    private let maxEntries = 5000
    private let formatter: DateFormatter
    /// Rotate the on-disk log once it grows past this, so a multi-day 24/7
    /// session stays readable and bounded (one backup is kept as `app.log.1`).
    private let maxFileBytes = 5_000_000
    private let maxBackups = 3
    private var writeCount = 0  // only touched on `queue`

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("UnifiProtectViewer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("app.log")
        crashFileURL = dir.appendingPathComponent("crash.log")

        formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"

        // Rotate instead of truncating so the previous crash/session evidence
        // always survives an automatic relaunch.
        AppLog.rotateIfOversize(fileURL, maximumBytes: maxFileBytes, backups: maxBackups)
        AppLog.rotateIfOversize(crashFileURL, maximumBytes: 2_000_000, backups: maxBackups)
        queue.async { [fileURL, formatter] in
            let header = "\n===== UniFi Protect Viewer launched \(formatter.string(from: Date())) =====\n"
            AppLog.append(header, to: fileURL)
        }
    }

    func log(_ message: String, level: Level = .info) {
        let entry = Entry(date: Date(), level: level, message: message)
        queue.async { [weak self, fileURL, formatter] in
            let line = entry.formatted(formatter) + "\n"
            AppLog.append(line, to: fileURL)
            self?.rotateIfNeeded(fileURL)
        }
        DispatchQueue.main.async {
            self.entries.append(entry)
            if self.entries.count > self.maxEntries {
                self.entries.removeFirst(self.entries.count - self.maxEntries)
            }
        }
        // Also mirror to the system log / Xcode console.
        NSLog("[%@] %@", level.rawValue, message)
    }

    func clear() {
        DispatchQueue.main.async { self.entries.removeAll() }
        queue.async { [fileURL, crashFileURL, maxBackups = self.maxBackups] in
            try? "".write(to: fileURL, atomically: true, encoding: .utf8)
            try? "".write(to: crashFileURL, atomically: true, encoding: .utf8)
            for index in 1...maxBackups {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: fileURL.path + ".\(index)"))
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: crashFileURL.path + ".\(index)"))
            }
        }
    }

    /// All in-memory entries joined into a single string (for copy/share).
    func exportText() -> String {
        let snapshot = entries
        return queue.sync {
            snapshot.map { $0.formatted(formatter) }.joined(separator: "\n")
        }
    }

    /// Rotate the log file mid-run when it exceeds `maxFileBytes`. Runs on
    /// `queue`; the size is only checked every so often to avoid statting the
    /// file on every write.
    private func rotateIfNeeded(_ url: URL) {
        writeCount += 1
        guard writeCount % 200 == 0 else { return }
        guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
              size > maxFileBytes else { return }
        AppLog.rotate(url, backups: maxBackups)
        let marker = "===== log rotated \(formatter.string(from: Date())) (previous files kept as app.log.1…\(maxBackups)) =====\n"
        AppLog.append(marker, to: url)
    }

    private static func rotateIfOversize(_ url: URL, maximumBytes: Int, backups: Int) {
        guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
              size > maximumBytes else { return }
        rotate(url, backups: backups)
    }

    private static func rotate(_ url: URL, backups: Int) {
        guard backups > 0 else { return }
        let fm = FileManager.default
        try? fm.removeItem(at: URL(fileURLWithPath: url.path + ".\(backups)"))
        if backups > 1 {
            for index in stride(from: backups - 1, through: 1, by: -1) {
                let source = URL(fileURLWithPath: url.path + ".\(index)")
                let destination = URL(fileURLWithPath: url.path + ".\(index + 1)")
                if fm.fileExists(atPath: source.path) {
                    try? fm.moveItem(at: source, to: destination)
                }
            }
        }
        if fm.fileExists(atPath: url.path) {
            try? fm.moveItem(at: url, to: URL(fileURLWithPath: url.path + ".1"))
        }
    }

    private static func append(_ string: String, to url: URL) {
        guard let data = string.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// Global convenience for logging from anywhere.
func appLog(_ message: String, _ level: AppLog.Level = .info) {
    AppLog.shared.log(message, level: level)
}

/// Lightweight process CPU / memory sampling for diagnostics.
enum SystemStats {
    static var activeProcessorCount: Int { ProcessInfo.processInfo.activeProcessorCount }

    /// Total CPU usage of this process across all threads, in percent. On a
    /// multi-core machine this can exceed 100% (e.g. 800% on 8 cores).
    static func cpuUsagePercent() -> Double {
        var threadsList: thread_act_array_t?
        var threadsCount = mach_msg_type_number_t(0)
        guard task_threads(mach_task_self_, &threadsList, &threadsCount) == KERN_SUCCESS,
              let threadsList = threadsList else { return 0 }
        defer {
            vm_deallocate(mach_task_self_,
                          vm_address_t(UInt(bitPattern: UnsafeMutableRawPointer(threadsList))),
                          vm_size_t(Int(threadsCount) * MemoryLayout<thread_t>.stride))
        }
        var total = 0.0
        let infoCount = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
        for i in 0..<Int(threadsCount) {
            var info = thread_basic_info()
            var count = infoCount
            let kr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
                ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    thread_info(threadsList[i], thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
                }
            }
            if kr == KERN_SUCCESS, (info.flags & TH_FLAGS_IDLE) == 0 {
                total += Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100.0
            }
        }
        return total
    }

    /// Resident memory footprint of the process, in megabytes.
    static func memoryFootprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / 1024.0 / 1024.0
    }
}

/// Best-effort crash capture: records uncaught Obj-C exceptions and fatal
/// signals to the app log file *before* the process dies, so a crash on an
/// unattended wall leaves a trace (in addition to the macOS crash report).
///
/// Note: this cannot catch out-of-memory (jetsam / SIGKILL) terminations — for
/// those, check `~/Library/Logs/DiagnosticReports/` for a JetsamEvent report.
enum CrashReporter {
    private static var installed = false
    private static var logFD: Int32 = -1
    private static let maxFrames = 128
    // Pre-allocated so the signal handler never has to allocate memory.
    private static let frameBuffer = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: maxFrames)
    private static let signalHeader = strdup("\n===== FATAL SIGNAL — backtrace follows (see also the macOS crash report) =====\n")

    static func install(logFileURL: URL) {
        guard !installed else { return }
        installed = true
        logFD = open(logFileURL.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)

        NSSetUncaughtExceptionHandler { exception in
            var text = "\n===== UNCAUGHT EXCEPTION =====\n"
            text += "name: \(exception.name.rawValue)\n"
            text += "reason: \(exception.reason ?? "(none)")\n"
            text += "stack:\n" + exception.callStackSymbols.joined(separator: "\n") + "\n"
            CrashReporter.writeRaw(text)
        }

        for sig in [SIGABRT, SIGILL, SIGSEGV, SIGBUS, SIGFPE, SIGTRAP] {
            signal(sig, CrashReporter.signalHandler)
        }
    }

    // C signal handler — must avoid allocations / non-async-signal-safe calls.
    private static let signalHandler: @convention(c) (Int32) -> Void = { sig in
        if let header = CrashReporter.signalHeader {
            _ = write(CrashReporter.logFD, header, strlen(header))
        }
        let count = backtrace(CrashReporter.frameBuffer, Int32(CrashReporter.maxFrames))
        backtrace_symbols_fd(CrashReporter.frameBuffer, count, CrashReporter.logFD)
        _ = fsync(CrashReporter.logFD)
        // Re-raise with the default handler so macOS still writes its crash report.
        signal(sig, SIG_DFL)
        raise(sig)
    }

    private static func writeRaw(_ string: String) {
        guard logFD >= 0 else { return }
        string.withCString { _ = write(logFD, $0, strlen($0)) }
        _ = fsync(logFD)
    }
}
