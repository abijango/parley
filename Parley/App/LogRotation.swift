import Foundation
import Synchronization
import OSLog

/// Rotates the live logs and zips what they replace.
///
/// `parley.log` and `freeze.log` stay plain text so the file Settings reveals is
/// always the current one. Once either reaches `Limits.maxActiveBytes` it is moved
/// into `archive/` and zipped. Older freeze stack dumps are zipped in place; the
/// newest stays plain. A hand-made archive such as `parley-logs-until-….zip` is
/// left alone. Zipped rotations beyond `maxArchives` (per log) are deleted, oldest
/// first.
enum LogRotation {
    struct Limits: Equatable {
        var maxActiveBytes: Int
        var maxArchives: Int
        /// Newest freeze stack dumps left as `.txt`. Older ones become `.txt.zip`.
        var plainFreezeCaptures: Int

        static let production = Limits(
            maxActiveBytes: 5 * 1024 * 1024,
            maxArchives: 8,
            plainFreezeCaptures: 1)
    }

    struct Entry: Equatable {
        var path: String
        var bytes: Int
    }

    enum Step: Equatable {
        case rotate(String)
        case zip(String)
        case delete(String)
    }

    private static let osLog = Logger(subsystem: AppInfo.name, category: "log")
    private static let compressQueue = DispatchQueue(label: "\(AppInfo.name).logcompress", qos: .utility)
    private static let compressPending = Mutex(false)
    private static let zipFailures = Mutex(Set<String>())

    /// Comparable identity for a freeze stack dump, plain or zipped.
    /// `freeze-2026-09-07-175227.txt` and the `.txt.zip` beside it share a key.
    static func freezeCaptureKey(_ name: String) -> String? {
        var stem = name
        if stem.hasSuffix(".zip") { stem.removeLast(4) }
        guard stem.hasPrefix("freeze-"), stem.hasSuffix(".txt") else { return nil }
        let body = stem.dropFirst("freeze-".count).dropLast(".txt".count)
        let parts = body.split(separator: "-").map(String.init)
        guard parts.count == 4,
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2, parts[3].count == 6,
              parts.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return nil }
        return stem
    }

    /// `parley` or `freeze` when `name` is a rotation this type created.
    static func rotatedFamily(_ name: String) -> String? {
        var stem = name
        if stem.hasSuffix(".zip") { stem.removeLast(4) }
        guard stem.hasSuffix(".log") else { return nil }
        stem.removeLast(4)
        let parts = stem.split(separator: "-").map(String.init)
        guard parts.count == 5 || parts.count == 6 else { return nil }
        guard parts[0] == "parley" || parts[0] == "freeze" else { return nil }
        guard parts[1].count == 4, parts[2].count == 2, parts[3].count == 2, parts[4].count == 6,
              parts[1...4].allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return nil }
        if parts.count == 6, !parts[5].allSatisfy(\.isNumber) { return nil }
        return parts[0]
    }

    static func plan(entries: [Entry], limits: Limits) -> [Step] {
        var steps: [Step] = []
        for name in ["parley.log", "freeze.log"] {
            if let entry = entries.first(where: { $0.path == name }), entry.bytes >= limits.maxActiveBytes, entry.bytes > 0 {
                steps.append(.rotate(name))
            }
        }

        let captures = entries
            .filter { !$0.path.contains("/") && freezeCaptureKey(fileName($0.path)) != nil }
            .sorted { freezeCaptureKey(fileName($0.path))! < freezeCaptureKey(fileName($1.path))! }
        let keepPlain = min(limits.plainFreezeCaptures, captures.count)
        for entry in captures.dropLast(keepPlain) where entry.path.hasSuffix(".txt") && !entry.path.hasSuffix(".zip") {
            steps.append(.zip(entry.path))
        }

        for entry in entries where entry.path.hasPrefix("archive/") && !entry.path.hasSuffix(".zip") {
            if rotatedFamily(fileName(entry.path)) != nil {
                steps.append(.zip(entry.path))
            }
        }

        let zips = entries.map(\.path).filter { path in
            path.hasPrefix("archive/") && path.hasSuffix(".log.zip") && rotatedFamily(fileName(path)) != nil
        }
        for family in ["parley", "freeze"] {
            let familyZips = zips
                .filter { rotatedFamily(fileName($0)) == family }
                .sorted()
            guard familyZips.count > limits.maxArchives else { continue }
            for path in familyZips.dropLast(limits.maxArchives) {
                steps.append(.delete(path))
            }
        }
        return steps
    }

    /// Move `activeFile` into `archive/` when it is at least `maxBytes`. The moved
    /// file stays plain until `scheduleCompression` zips it. Returns true when a
    /// file was moved.
    @discardableResult
    static func rotateActiveFileIfNeeded(
        _ activeFile: URL,
        maxBytes: Int = Limits.production.maxActiveBytes,
        now: Date = Date(),
        force: Bool = false
    ) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: activeFile.path) else { return false }
        let size = fileSize(activeFile)
        if force {
            guard size > 0 else { return false }
        } else {
            guard size >= maxBytes else { return false }
        }
        let archive = activeFile.deletingLastPathComponent().appendingPathComponent("archive", isDirectory: true)
        do {
            try fm.createDirectory(at: archive, withIntermediateDirectories: true)
            let dest = uniqueRotationURL(in: archive, source: activeFile, now: now)
            try fm.moveItem(at: activeFile, to: dest)
            osLog.log("rotated \(activeFile.lastPathComponent, privacy: .public) → \(dest.lastPathComponent, privacy: .public)")
            return true
        } catch {
            osLog.error("log rotate failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Zip older logs on a utility queue. Coalesced, so a burst of log lines schedules one pass.
    static func scheduleCompression(of directory: URL, limits: Limits = .production) {
        compressQueue.async {
            let alreadyPending = compressPending.withLock { pending in
                defer { pending = true }
                return pending
            }
            guard !alreadyPending else { return }
            compressQueue.async {
                compressPending.withLock { $0 = false }
                compressSettled(directory: directory, limits: limits)
            }
        }
    }

    /// Rotate, zip, and prune synchronously. Tests use this; the app rotates on the
    /// writer and zips afterwards.
    static func maintain(directory: URL, limits: Limits, now: Date = Date()) {
        for _ in 0..<3 {
            let steps = plan(entries: list(directory: directory), limits: limits)
            if steps.isEmpty { break }
            apply(steps, directory: directory, now: now, limits: limits)
        }
    }

    static func list(directory: URL) -> [Entry] {
        var entries: [Entry] = []
        func add(dir: URL, prefix: String) {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
            for name in names {
                let url = dir.appendingPathComponent(name)
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { continue }
                entries.append(Entry(path: prefix + name, bytes: fileSize(url)))
            }
        }
        add(dir: directory, prefix: "")
        add(dir: directory.appendingPathComponent("archive", isDirectory: true), prefix: "archive/")
        return entries
    }

    // MARK: - Private

    private static func compressSettled(directory: URL, limits: Limits) {
        for _ in 0..<3 {
            let steps = plan(entries: list(directory: directory), limits: limits).filter {
                if case .rotate = $0 { return false }
                return true
            }
            if steps.isEmpty { return }
            apply(steps, directory: directory, now: Date(), limits: limits)
        }
    }

    private static func apply(_ steps: [Step], directory: URL, now: Date, limits: Limits) {
        for step in steps {
            switch step {
            case .rotate(let name):
                rotateActiveFileIfNeeded(url(directory, name), maxBytes: limits.maxActiveBytes, now: now, force: true)
            case .zip(let relative):
                zipReplacing(url(directory, relative))
            case .delete(let relative):
                try? FileManager.default.removeItem(at: url(directory, relative))
            }
        }
    }

    private static func zipReplacing(_ file: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: file.path), !file.path.hasSuffix(".zip") else { return }
        if zipFailures.withLock({ $0.contains(file.path) }) { return }
        let zipURL = file.appendingPathExtension("zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = file.deletingLastPathComponent()
        process.arguments = ["-q", "-j", "-m", zipURL.lastPathComponent, file.lastPathComponent]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0, fm.fileExists(atPath: zipURL.path) else {
                zipFailures.withLock { _ = $0.insert(file.path) }
                osLog.error("log zip failed (\(process.terminationStatus)) for \(file.lastPathComponent, privacy: .public)")
                return
            }
        } catch {
            zipFailures.withLock { _ = $0.insert(file.path) }
            osLog.error("log zip failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func uniqueRotationURL(in archive: URL, source: URL, now: Date) -> URL {
        let fm = FileManager.default
        let stem = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        let stamp = fileStamp(now)
        var dest = archive.appendingPathComponent("\(stem)-\(stamp).\(ext)")
        var n = 2
        while fm.fileExists(atPath: dest.path) || fm.fileExists(atPath: dest.appendingPathExtension("zip").path) {
            dest = archive.appendingPathComponent("\(stem)-\(stamp)-\(n).\(ext)")
            n += 1
        }
        return dest
    }

    private static func fileStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f.string(from: date)
    }

    private static func fileName(_ relative: String) -> String {
        String(relative.split(separator: "/").last ?? Substring(relative))
    }

    private static func url(_ directory: URL, _ relative: String) -> URL {
        relative.split(separator: "/").reduce(directory) { $0.appendingPathComponent(String($1)) }
    }

    private static func fileSize(_ url: URL) -> Int {
        let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size]
        return (size as? NSNumber)?.intValue ?? 0
    }
}
