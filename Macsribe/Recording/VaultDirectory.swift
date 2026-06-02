import Foundation

/// A filing destination = a folder anywhere in the scanned roots of the vault.
struct VaultDestination: Identifiable, Hashable {
    let path: String       // vault-relative, e.g. "Internal/Customers/Vanguard"
    var id: String { path }

    /// Human display, e.g. "Internal / Customers / Vanguard".
    var display: String { path.split(separator: "/").joined(separator: " / ") }
    /// Last path component, e.g. "Vanguard".
    var leaf: String { path.split(separator: "/").last.map(String.init) ?? path }
    /// Immediate parent component, e.g. "Customers".
    var parent: String? {
        let parts = path.split(separator: "/")
        return parts.count >= 2 ? String(parts[parts.count - 2]) : nil
    }
    var isCustomer: Bool { parent?.caseInsensitiveCompare("Customers") == .orderedSame }
}

/// A likely-same customer spelled differently in folders vs the contacts file.
struct CustomerNearMatch: Identifiable {
    var id: String { folderName + "|" + fileName }
    let folderName: String
    let fileName: String
    let reason: String
}

/// Cross-check of customer folders against the contacts file.
struct CustomerReconciliation {
    let matched: [String]
    let folderOnly: [String]
    let fileOnly: [String]
    let nearMatches: [CustomerNearMatch]
    var isClean: Bool { folderOnly.isEmpty && fileOnly.isEmpty && nearMatches.isEmpty }
}

/// In-memory index of filing destinations (folders) and contacts, prefetched
/// from the Obsidian vault for instant type-ahead. The vault stays the single
/// source of truth: destinations are folders under the configured scan roots,
/// contacts are parsed from the contacts file (Rolodex.md). New entries are
/// written straight back to the vault.
@MainActor
final class VaultDirectory: ObservableObject {
    @Published private(set) var destinations: [VaultDestination] = []  // folders in scan roots
    @Published private(set) var people: [String] = []                  // names in the contacts file
    @Published private(set) var fileCustomers: [String] = []           // "Customers:" section of contacts file

    private let settings = AppSettings.shared
    private static let maxDepth = 4
    /// Folders never offered as destinations.
    private static let excludedNames: Set<String> = [
        "Unsorted Transcripts", "Processed Transcripts", "Raw Transcripts", "Attachments", "_attachments",
    ]

    /// Rebuild indexes from disk. Cheap (hundreds of entries).
    func refresh() {
        migrateContactsFileIfNeeded()
        destinations = loadDestinations()
        people = loadPeople()
        fileCustomers = loadFileCustomers()
        AppLog.log("Vault index refreshed — \(destinations.count) destinations, \(people.count) contacts", category: "vault")
    }

    // MARK: One-time contacts-file rename (Key People.md → Rolodex.md)

    private func migrateContactsFileIfNeeded() {
        let fm = FileManager.default
        let target = settings.contactsURL
        let legacy = settings.legacyContactsURL
        guard !fm.fileExists(atPath: target.path),
              fm.fileExists(atPath: legacy.path),
              target.lastPathComponent != legacy.lastPathComponent else { return }
        do {
            try fm.moveItem(at: legacy, to: target)
            AppLog.log("Migrated \(legacy.lastPathComponent) → \(target.lastPathComponent)", category: "vault")
        } catch {
            AppLog.log("Contacts migration failed: \(error.localizedDescription)", category: "vault")
        }
    }

    // MARK: Destinations (folder tree)

    private func loadDestinations() -> [VaultDestination] {
        var result: [VaultDestination] = []
        let fm = FileManager.default
        for root in settings.scanRoots {
            let rootURL = settings.vaultURL.appendingPathComponent(root, isDirectory: true)
            guard fm.fileExists(atPath: rootURL.path) else { continue }
            walk(rootURL, relative: root, depth: 0, into: &result)
        }
        return result.sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
    }

    private func walk(_ url: URL, relative: String, depth: Int, into result: inout [VaultDestination]) {
        guard depth < Self.maxDepth else { return }
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return }

        for item in items {
            guard (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let name = item.lastPathComponent
            if Self.excludedNames.contains(name) || Self.isStatusFolder(name) { continue }
            let relPath = relative + "/" + name
            result.append(VaultDestination(path: relPath))
            walk(item, relative: relPath, depth: depth + 1, into: &result)
        }
    }

    /// Pipeline-status groupers like "00 - Thesis Validation" are not destinations.
    private static func isStatusFolder(_ name: String) -> Bool {
        name.range(of: #"^\d+\s*-\s"#, options: .regularExpression) != nil
    }

    /// Creates a destination folder (and intermediate folders) if missing, then refreshes.
    func ensureDestination(_ relPath: String) {
        let clean = sanitizePath(relPath)
        guard !clean.isEmpty else { return }
        let url = settings.vaultURL.appendingPathComponent(clean, isDirectory: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            AppLog.log("Created destination folder: \(clean)", category: "vault")
        }
        refresh()
    }

    // MARK: Contacts (Rolodex.md)

    private func loadPeople() -> [String] {
        guard let text = try? String(contentsOf: settings.contactsURL, encoding: .utf8) else { return [] }
        var names: [String] = []
        var seen = Set<String>()
        text.enumerateLines { line, _ in
            if let name = Self.extractName(from: line), seen.insert(name.lowercased()).inserted {
                names.append(name)
            }
        }
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private static func extractName(from line: String) -> String? {
        for pattern in [#"\*\*(.+?)\*\*"#, #"\[(.+?)\]\("#] {
            if let match = firstCapture(pattern, in: line) {
                let cleaned = match.trimmingCharacters(in: .whitespaces)
                if !cleaned.isEmpty { return cleaned }
            }
        }
        return nil
    }

    private static func firstCapture(_ pattern: String, in string: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(string.startIndex..., in: string)
        guard let match = regex.firstMatch(in: string, range: range), match.numberOfRanges > 1,
              let r = Range(match.range(at: 1), in: string) else { return nil }
        return String(string[r])
    }

    /// Appends not-yet-known people to the contacts file under a managed section.
    func addPeople(_ rawNames: [String]) {
        let known = Set(people.map { $0.lowercased() })
        let fresh = rawNames
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !known.contains($0.lowercased()) }
        guard !fresh.isEmpty else { return }

        let url = settings.contactsURL
        var contents = (try? String(contentsOf: url, encoding: .utf8)) ?? "Contacts\n"
        let marker = "## Added by \(AppInfo.name)"   // TODO(app-name)
        if !contents.contains(marker) { contents += "\n\n\(marker)\n" }
        for name in fresh { contents += "    - **\(name)**\n" }

        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? contents.write(to: url, atomically: true, encoding: .utf8)
        AppLog.log("Added \(fresh.count) contacts to \(url.lastPathComponent)", category: "vault")
        refresh()
    }

    /// Adds a single rich contact to the contacts file, matching the existing
    /// format. Files it under a section header equal to `company` if one exists,
    /// otherwise under a managed section. Then refreshes.
    func addPerson(name rawName: String, title rawTitle: String, company rawCompany: String, linkedin rawLink: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let title = rawTitle.trimmingCharacters(in: .whitespaces)
        let company = rawCompany.trimmingCharacters(in: .whitespaces)
        let link = rawLink.trimmingCharacters(in: .whitespaces)

        let nameMD = link.isEmpty ? "**\(name)**" : "[\(name)](\(link))"
        let role = [title, company].filter { !$0.isEmpty }.joined(separator: ", ")
        let entry = "    - \(nameMD)\(role.isEmpty ? "" : " - \(role)")"

        let url = settings.contactsURL
        var lines = ((try? String(contentsOf: url, encoding: .utf8)) ?? "Contacts").components(separatedBy: "\n")

        if !company.isEmpty,
           let idx = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(company) == .orderedSame }) {
            lines.insert(entry, at: idx + 1)           // under the company's section
        } else {
            let marker = "## Added by \(AppInfo.name)"   // TODO(app-name)
            if !lines.contains(where: { $0.trimmingCharacters(in: .whitespaces) == marker }) {
                lines.append(""); lines.append(marker)
            }
            lines.append(entry)
        }

        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        AppLog.log("Added contact \(name)\(company.isEmpty ? "" : " under \(company)") to \(url.lastPathComponent)", category: "vault")
        refresh()
    }

    private func loadFileCustomers() -> [String] {
        guard let text = try? String(contentsOf: settings.contactsURL, encoding: .utf8) else { return [] }
        var inSection = false
        var result: [String] = []
        var seen = Set<String>()
        text.enumerateLines { line, stop in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !inSection {
                if trimmed.lowercased() == "customers:" || trimmed.lowercased() == "customers" { inSection = true }
                return
            }
            if trimmed.isEmpty || trimmed.hasPrefix("-") { return }
            if trimmed.hasSuffix(":") { stop = true; return }
            if seen.insert(trimmed.lowercased()).inserted { result.append(trimmed) }
        }
        return result.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    // MARK: Reconciliation (Customers folders ⟷ contacts file)

    /// Customer leaf names — destinations whose parent folder is "Customers".
    var customerFolderNames: [String] {
        destinations.filter { $0.isCustomer }.map { $0.leaf }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func reconcileCustomers() -> CustomerReconciliation {
        let folders = customerFolderNames
        let fileList = fileCustomers
        var matched: [String] = []
        var near: [CustomerNearMatch] = []
        var folderOnly: [String] = []
        var usedFile = Set<String>()

        for folder in folders {
            if let exact = fileList.first(where: { $0.caseInsensitiveCompare(folder) == .orderedSame }) {
                matched.append(folder); usedFile.insert(exact.lowercased())
            } else if let nm = fileList.first(where: {
                !usedFile.contains($0.lowercased()) && Self.areNear(folder, $0)
            }) {
                near.append(CustomerNearMatch(folderName: folder, fileName: nm, reason: Self.nearReason(folder, nm)))
                usedFile.insert(nm.lowercased())
            } else {
                folderOnly.append(folder)
            }
        }
        let fileOnly = fileList.filter { !usedFile.contains($0.lowercased()) }
        return CustomerReconciliation(matched: matched, folderOnly: folderOnly, fileOnly: fileOnly, nearMatches: near)
    }

    private static func normalize(_ s: String) -> String {
        s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }
    private static func areNear(_ a: String, _ b: String) -> Bool {
        let na = normalize(a), nb = normalize(b)
        guard !na.isEmpty, !nb.isEmpty else { return false }
        if na == nb { return true }
        if na.count > 3, nb.count > 3, (na.contains(nb) || nb.contains(na)) { return true }
        return min(na.count, nb.count) > 3 && levenshtein(na, nb) <= 2
    }
    private static func nearReason(_ folder: String, _ file: String) -> String {
        let nf = normalize(folder), ff = normalize(file)
        if nf == ff { return "same name, different casing/punctuation" }
        if nf.contains(ff) || ff.contains(nf) { return "one name has extra words" }
        return "possible spelling difference"
    }
    private static func levenshtein(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        var d = Array(0...y.count)
        for i in 1...x.count {
            var prev = d[0]; d[0] = i
            for j in 1...y.count {
                let temp = d[j]
                d[j] = x[i-1] == y[j-1] ? prev : min(prev, d[j], d[j-1]) + 1
                prev = temp
            }
        }
        return d[y.count]
    }

    // MARK: Filtering (instant, in-memory)

    func filteredDestinations(_ query: String) -> [VaultDestination] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return destinations }
        let prefix = destinations.filter { $0.display.lowercased().hasPrefix(q) || $0.leaf.lowercased().hasPrefix(q) }
        let contains = destinations.filter {
            !prefix.contains($0) && $0.display.lowercased().contains(q)
        }
        return prefix + contains
    }

    func filteredPeople(_ query: String) -> [String] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return people }
        let prefix = people.filter { $0.lowercased().hasPrefix(q) }
        let contains = people.filter { !$0.lowercased().hasPrefix(q) && $0.lowercased().contains(q) }
        return prefix + contains
    }

    private func sanitizePath(_ path: String) -> String {
        path.split(separator: "/")
            .map { component -> String in
                let illegal = CharacterSet(charactersIn: ":\\?%*|\"<>")
                return component.trimmingCharacters(in: .whitespaces)
                    .components(separatedBy: illegal).joined(separator: "-")
            }
            .filter { !$0.isEmpty }
            .joined(separator: "/")
    }
}
