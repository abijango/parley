import Foundation
import OSLog

/// Lightweight file logger for investigating issues, plus OSLog mirroring.
///
/// Writes timestamped lines to `~/Library/Logs/<App>/macsribe.log` on a serial
/// queue (safe to call from any thread/actor). Reveal it from Settings.
/// TODO(app-name): log file name.
enum AppLog {
    static var directory: URL {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Logs/\(AppInfo.name)", isDirectory: true)
    }
    static var fileURL: URL { directory.appendingPathComponent("macsribe.log") }

    private static let queue = DispatchQueue(label: "\(AppInfo.name).applog")
    private static let osLog = Logger(subsystem: AppInfo.name, category: "app")
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func log(_ message: String, category: String = "app") {
        let date = Date()
        osLog.log("[\(category, privacy: .public)] \(message, privacy: .public)")
        queue.async {
            let line = "\(stamp.string(from: date)) [\(category)] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            let fm = FileManager.default
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                handle.write(data)
            } else {
                try? data.write(to: fileURL)
            }
        }
    }

    static func clear() {
        queue.async { try? FileManager.default.removeItem(at: fileURL) }
    }
}
