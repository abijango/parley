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

/// Which side of a meeting a person is on.
enum Side: String, Equatable, CaseIterable {
    case internalTeam = "internal"
    case customer     = "customer"
    case other        = "other"
}

/// A parsed contact entry from Rolodex.md.
///
/// - `company` is nil when the contact is under "Other" (or before any section header).
/// - `side` is .internalTeam for your own org, .customer for customer companies,
///   .other for the catch-all "Other" section.
/// - `title` is the opaque trailing text after the name markup (e.g. "Senior Engineer").
///   Nil when absent, preserved verbatim including trailing annotations like *(unconfirmed)*.
/// - `linkedin` is the URL from the [Name](url) link form, or nil for bold-name bullets.
/// - `aliases` is a list of known alternative display names (e.g. Teams/Zoom names that
///   differ from the canonical name). Parsed from `(aka A, B)` after the name token.
///   Stored sorted for determinism. Default empty.
/// - `displayRole` is a legacy alias for title that returns "" when nil — kept for backward
///   compatibility with callers that expect a non-optional String.
struct Contact: Equatable {
    let name: String
    let company: String?
    let side: Side
    let title: String?
    let linkedin: String?
    var aliases: [String] = []

    /// Legacy alias for title. Returns the empty string when title is nil.
    var displayRole: String { title ?? "" }
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
    @Published private(set) var contacts: [Contact] = []               // full contact records (name + company + aliases)
    @Published private(set) var fileCustomers: [String] = []           // customer companies from contacts file

    /// Company index built during refresh(). Maps lowercased name to the set of
    /// distinct non-"Other" companies the name appears under. Used by company(for:).
    /// - empty set  -> name is only under Other (or no section) -> company returns nil
    /// - one entry  -> unambiguous company
    /// - two+ entries -> collision -> company returns nil and logs a warning
    private var companyIndex: [String: Set<String>] = [:]

    /// Side index built during refresh(). Maps lowercased name to Side.
    /// Collision rule: if a name appears under two different sides, side returns nil (logged).
    private var sideIndex: [String: Set<Side>] = [:]

    private var refreshTask: Task<Void, Never>?

    private let settings = AppSettings.shared
    private static let maxDepth = 4
    /// Folders never offered as destinations.
    private static let excludedNames: Set<String> = [
        "Unsorted Transcripts", "Processed Transcripts", "Raw Transcripts", "Attachments", "_attachments",
    ]

    /// Section for contacts with no company (matches the manual "Castlelake"-style
    /// grouping: a plain header line followed by column-0 bullets).
    nonisolated static let otherSection = "Other"

    // MARK: - Refresh

    /// Rebuild indexes from disk.
    ///
    /// Callers observe the result via the `@Published` properties; `refresh()` returns
    /// immediately and does not block the caller. In-flight scans are cancelled and
    /// superseded so overlapping calls cannot publish out of order.
    ///
    /// Pass `waitForCompletion: true` when the caller needs the indexes updated before
    /// returning (tests, immediately after a local vault write).
    func refresh(waitForCompletion: Bool = false) {
        migrateContactsFileIfNeeded()
        if waitForCompletion {
            refreshAfterMutation()
        } else {
            scheduleBackgroundRefresh()
        }
    }

    /// Re-reads disk and publishes immediately — for callers that just wrote the vault
    /// and need the in-memory index to match before returning.
    private func refreshAfterMutation() {
        refreshTask?.cancel()
        migrateContactsFileIfNeeded()
        applySnapshot(Self.buildSnapshot(
            vaultURL: settings.vaultURL,
            contactsURL: settings.contactsURL,
            scanRoots: settings.scanRoots
        ))
    }

    private func scheduleBackgroundRefresh() {
        refreshTask?.cancel()
        let vaultURL = settings.vaultURL
        let contactsURL = settings.contactsURL
        let scanRoots = settings.scanRoots
        refreshTask = Task { [weak self] in
            let snapshot = await Task.detached {
                Self.buildSnapshot(vaultURL: vaultURL, contactsURL: contactsURL, scanRoots: scanRoots)
            }.value
            guard !Task.isCancelled, let self else { return }
            applySnapshot(snapshot)
        }
    }

    private func applySnapshot(_ snapshot: VaultRefreshSnapshot) {
        destinations = snapshot.destinations
        people = snapshot.people
        contacts = snapshot.contacts
        companyIndex = snapshot.companyIndex
        sideIndex = snapshot.sideIndex
        fileCustomers = snapshot.fileCustomers
        AppLog.log("Vault index refreshed -- \(destinations.count) destinations, \(people.count) contacts", category: "vault")
    }

    private struct VaultRefreshSnapshot: Sendable {
        let destinations: [VaultDestination]
        let people: [String]
        let contacts: [Contact]
        let fileCustomers: [String]
        let companyIndex: [String: Set<String>]
        let sideIndex: [String: Set<Side>]
    }

    nonisolated private static func buildSnapshot(
        vaultURL: URL, contactsURL: URL, scanRoots: [String]
    ) -> VaultRefreshSnapshot {
        let destinations = loadDestinations(vaultURL: vaultURL, scanRoots: scanRoots)
        let contactsText = (try? String(contentsOf: contactsURL, encoding: .utf8)) ?? ""
        let contacts = parseContacts(contactsText)

        var seen = Set<String>()
        var names: [String] = []
        for c in contacts {
            let key = c.name.lowercased()
            if seen.insert(key).inserted { names.append(c.name) }
            for alias in c.aliases {
                let aKey = alias.lowercased()
                if seen.insert(aKey).inserted { names.append(alias) }
            }
        }
        let people = names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

        var cIndex: [String: Set<String>] = [:]
        var sIndex: [String: Set<Side>] = [:]
        for c in contacts {
            let keysToRegister: [String] = [c.name.lowercased()] + c.aliases.map { $0.lowercased() }
            for key in keysToRegister {
                sIndex[key, default: []].insert(c.side)
                if let company = c.company {
                    cIndex[key, default: []].insert(company)
                } else {
                    if cIndex[key] == nil { cIndex[key] = [] }
                }
            }
        }
        for (key, companies) in cIndex where companies.count >= 2 {
            AppLog.log("VaultDirectory: name collision -- \(key) appears under \(companies.sorted().joined(separator: ", "))", category: "vault")
        }

        let fileCustomers = loadFileCustomers(contacts: contacts)
        return VaultRefreshSnapshot(
            destinations: destinations,
            people: people,
            contacts: contacts,
            fileCustomers: fileCustomers,
            companyIndex: cIndex,
            sideIndex: sIndex
        )
    }

    // MARK: - Contact parsing (nonisolated static -- safe to call off @MainActor)

    /// Parse the full Rolodex.md text into structured Contact values.
    ///
    /// Tolerant: reads both canonical (#/## /### headings) and legacy formats
    /// (colon headers like "Intellias Team:", bare company names, tab/space indented bullets,
    /// plain "- Name - Title" bullets with no **bold** or [link]() markup).
    ///
    /// Heading state machine:
    /// - customerMode starts false.
    /// - A heading whose name ci-equals "Customers" sets customerMode = true (no company emitted).
    /// - A heading whose name ci-equals "Other" sets customerMode = false, side = .other, company = nil.
    /// - A heading that maps to "Intellias" (ci-equals "Intellias" or "Intellias Team"):
    ///   sets customerMode = false, company = "Intellias", side = .internalTeam.
    /// - A canonical ## heading (level 2) sets customerMode = false, company = name, side = .internalTeam.
    /// - A canonical ### heading (level 3) sets company = name, side = .customer.
    /// - A level-0 legacy bare heading: if customerMode -> side = .customer; else -> .internalTeam.
    ///   Legacy bare headings do NOT exit customer mode.
    ///
    /// Bullet extraction priority: **Name**, then [Name](url), then plain split on " - ".
    nonisolated static func parseContacts(_ text: String) -> [Contact] {
        var result: [Contact] = []

        // Active section state.
        var currentCompany: String? = nil
        var currentSide: Side = .other
        var customerMode = false

        text.enumerateLines { line, _ in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }

            // -- Heading detection --
            if let (level, headingName) = parseHeading(trimmed) {
                let canonical = canonicalCompanyName(headingName)

                if canonical.caseInsensitiveCompare("Customers") == .orderedSame {
                    // Umbrella "Customers" heading -- sets customer mode; no company.
                    customerMode = true
                    currentCompany = nil
                    currentSide = .customer
                    return
                }

                if canonical.caseInsensitiveCompare(otherSection) == .orderedSame {
                    // "Other" heading -- resets customer mode.
                    customerMode = false
                    currentCompany = nil
                    currentSide = .other
                    return
                }

                if canonical.caseInsensitiveCompare("Intellias") == .orderedSame {
                    // Internal org heading (handles "Intellias Team" -> "Intellias").
                    customerMode = false
                    currentCompany = "Intellias"
                    currentSide = .internalTeam
                    return
                }

                if level == 2 {
                    // Canonical ## heading = internal company (top-level, exits customer mode).
                    customerMode = false
                    currentCompany = canonical
                    currentSide = .internalTeam
                    return
                }

                if level == 3 {
                    // Canonical ### heading = customer sub-section.
                    currentCompany = canonical
                    currentSide = .customer
                    return
                }

                // level == 0 (legacy bare / colon header) -- inherits customer mode.
                currentCompany = canonical
                currentSide = customerMode ? .customer : .internalTeam
                return
            }

            // -- Bullet detection --
            // A line is a bullet when its stripped form starts with "-".
            guard trimmed.hasPrefix("-") else { return }

            // Extract: try bold, then link, then plain split.
            let (name, title, linkedin, aliases) = extractBulletFields(trimmed)
            guard !name.isEmpty else { return }

            var c = Contact(
                name: name,
                company: currentCompany,
                side: currentSide,
                title: title,
                linkedin: linkedin
            )
            c.aliases = aliases.sorted()
            result.append(c)
        }
        return result
    }

    // MARK: Heading helpers

    /// Returns (level, name) for a heading line, or nil if not a heading.
    ///
    /// Heading forms:
    /// - Markdown: "## Company" -> level 2, name "Company"
    /// - Colon suffix: "Company:" -> level 0, name "Company"
    /// - Non-bullet bare line: level 0, name = trimmed text
    ///
    /// A bullet line (starts with "-") is NEVER a heading.
    nonisolated private static func parseHeading(_ trimmed: String) -> (level: Int, name: String)? {
        // Must not be a bullet.
        if trimmed.hasPrefix("-") { return nil }

        // Markdown heading: leading #s
        if trimmed.hasPrefix("#") {
            var level = 0
            var rest = trimmed[...]
            while rest.hasPrefix("#") { level += 1; rest = rest.dropFirst() }
            let name = rest.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: ":"))
                .trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            return (level, name)
        }

        // Bare non-bullet line is a legacy heading.
        var name = trimmed
        if name.hasSuffix(":") { name = String(name.dropLast()).trimmingCharacters(in: .whitespaces) }
        guard !name.isEmpty else { return nil }
        return (0, name)
    }

    /// Strips trailing ":" and maps legacy variants to canonical company names.
    nonisolated private static func canonicalCompanyName(_ raw: String) -> String {
        var s = raw
        if s.hasSuffix(":") { s = String(s.dropLast()).trimmingCharacters(in: .whitespaces) }
        // "Intellias Team" -> "Intellias" (all other names pass through unchanged)
        if s.caseInsensitiveCompare("Intellias Team") == .orderedSame { return "Intellias" }
        return s
    }

    // MARK: Bullet field extraction

    /// Extract (name, title, linkedin, aliases) from a bullet line.
    ///
    /// Priority:
    /// 1. Bold: - **Name** (aka A, B) - Title
    /// 2. Link:  - [Name](url) (aka A, B) - Title  (captures linkedin url)
    /// 3. Plain: - Name - Title                     (split on first " - "; no aka support)
    ///
    /// "Title" is nil when empty or absent. LinkedIn is nil for bold/plain bullets.
    /// Stray trailing chars after the closing ")" of a link are ignored (handles `)i` oddity).
    ///
    /// Aka detection: when the text after the name token (before the " - Title" separator)
    /// starts with "(aka " (case-insensitive), it is parsed as a comma-separated alias list
    /// and NOT included in the title. Any other parenthetical (e.g. "(London)", "(AWS)")
    /// passes through as part of the title text.
    nonisolated static func extractBulletFields(_ line: String) -> (name: String, title: String?, linkedin: String?, aliases: [String]) {
        let stripped = line.trimmingCharacters(in: .whitespacesAndNewlines)
        // Remove leading "- " (with any leading spaces before "-")
        let body: String
        if let dashRange = stripped.range(of: "-") {
            body = String(stripped[dashRange.upperBound...]).trimmingCharacters(in: .whitespaces)
        } else {
            return ("", nil, nil, [])
        }

        // Try bold: **Name**
        if let (name, rest) = extractBold(body) {
            let (aliases, remainingRest) = extractAka(rest)
            let title = cleanTitle(remainingRest)
            return (name, title.isEmpty ? nil : title, nil, aliases)
        }

        // Try link: [Name](url)
        if let (name, url, rest) = extractLink(body) {
            let (aliases, remainingRest) = extractAka(rest)
            let title = cleanTitle(remainingRest)
            return (name, title.isEmpty ? nil : title, url.isEmpty ? nil : url, aliases)
        }

        // Plain split on first " - " (space-dash-space to protect hyphenated names).
        // A line like "- Antonio MORISCO - " ends with a lone "-" after outer trimming strips
        // the trailing space, so the space-dash-space separator never fires and the trailing "-"
        // ends up baked into the name.  Strip any dangling trailing " -" or "-" from the name
        // component so "Antonio MORISCO -" becomes "Antonio MORISCO".
        let parts = body.components(separatedBy: " - ")
        var name = parts[0].trimmingCharacters(in: .whitespaces)
        // Strip a lone trailing "-" that represents an empty-role separator.
        if name.hasSuffix(" -") {
            name = String(name.dropLast(2)).trimmingCharacters(in: .whitespaces)
        } else if name.hasSuffix("-") && !name.dropLast().isEmpty {
            // Only strip a bare trailing "-" when it's not the whole name.
            let candidate = String(name.dropLast()).trimmingCharacters(in: .whitespaces)
            if !candidate.isEmpty { name = candidate }
        }
        if name.isEmpty { return ("", nil, nil, []) }
        let rest = parts.dropFirst().joined(separator: " - ").trimmingCharacters(in: .whitespaces)
        let title = rest.isEmpty ? nil : rest
        return (name, title, nil, [])
    }

    /// If `rest` starts with `(aka ...)` (case-insensitive), extract the comma-separated
    /// alias list and return `(aliases, remainderAfterAka)`.
    /// Otherwise returns `([], rest)` unchanged so the caller can proceed normally.
    nonisolated private static func extractAka(_ rest: String) -> (aliases: [String], remainder: String) {
        let trimmed = rest.trimmingCharacters(in: .whitespaces)
        // Must start with "(" and the content must begin with "aka" (ci).
        guard trimmed.hasPrefix("(") else { return ([], rest) }
        let inner = trimmed.dropFirst()  // drop "("
        guard inner.lowercased().hasPrefix("aka") else { return ([], rest) }

        // Find the matching closing paren.
        guard let closeIdx = trimmed.firstIndex(of: ")") else { return ([], rest) }
        // Content between "(" and ")".
        let akaContent = String(trimmed[trimmed.index(after: trimmed.startIndex)..<closeIdx])
        // Strip the leading "aka" word (case-insensitive).
        let afterAka = String(akaContent.dropFirst(3)).trimmingCharacters(in: .whitespaces)

        // Parse comma-separated alias names, ignoring empty tokens.
        let aliases = afterAka
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // Remainder is everything after the closing ")".
        let afterParen = String(trimmed[trimmed.index(after: closeIdx)...]).trimmingCharacters(in: .whitespaces)
        return (aliases, afterParen)
    }

    /// Extract bold name and trailing text: **Name** rest
    nonisolated private static func extractBold(_ body: String) -> (name: String, rest: String)? {
        guard body.hasPrefix("**") else { return nil }
        let afterOpen = body.dropFirst(2)
        guard let closeRange = afterOpen.range(of: "**") else { return nil }
        let name = String(afterOpen[..<closeRange.lowerBound]).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        let rest = String(afterOpen[closeRange.upperBound...]).trimmingCharacters(in: .whitespaces)
        return (name, rest)
    }

    /// Extract link name, URL, and trailing text: [Name](url) rest
    nonisolated private static func extractLink(_ body: String) -> (name: String, url: String, rest: String)? {
        guard body.hasPrefix("[") else { return nil }
        let afterOpen = body.dropFirst()
        guard let closeBracket = afterOpen.firstIndex(of: "]") else { return nil }
        let name = String(afterOpen[..<closeBracket]).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }

        let afterBracket = afterOpen[afterOpen.index(after: closeBracket)...]
        guard afterBracket.hasPrefix("(") else { return nil }
        let afterParen = afterBracket.dropFirst()
        guard let closeParen = afterParen.firstIndex(of: ")") else { return nil }
        let url = String(afterParen[..<closeParen])

        // Skip any stray alphanumeric/symbol chars directly after ")" (handles ")i" oddity).
        // A "(" is NOT stripped -- it starts a legitimate parenthetical such as "(aka ...)".
        var rest = String(afterParen[afterParen.index(after: closeParen)...]).trimmingCharacters(in: .whitespaces)
        // Stray non-space, non-paren chars right at start that aren't " - " -> strip them.
        // This handles the Addy Dubhash `)i` case where "i" is fused to the closing ")".
        if !rest.isEmpty && !rest.hasPrefix("-") && !rest.hasPrefix(" ") && !rest.hasPrefix("(") {
            // Drop non-space chars until we hit a space or end.
            rest = rest.drop(while: { !$0.isWhitespace }).trimmingCharacters(in: .whitespaces)
        }
        return (name, url, rest)
    }

    /// Strip a leading " - " separator and trim whitespace from trailing text.
    nonisolated private static func cleanTitle(_ raw: String) -> String {
        var s = raw
        if s.hasPrefix("- ") { s = String(s.dropFirst(2)) }
        return s.trimmingCharacters(in: .whitespaces)
    }

    // MARK: Legacy extractName (kept for upsertPerson bullet removal)

    nonisolated static func extractName(from line: String) -> String? {
        let (name, _, _, _) = extractBulletFields(line)
        return name.isEmpty ? nil : name
    }

    /// Extract the trailing role text from a bullet line after the name markup.
    /// Legacy compatibility shim; new code uses extractBulletFields.
    nonisolated private static func trailingRole(from line: String, name: String) -> String {
        let (_, title, _, _) = extractBulletFields(line)
        return title ?? ""
    }

    nonisolated private static func firstCapture(_ pattern: String, in string: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(string.startIndex..., in: string)
        guard let match = regex.firstMatch(in: string, range: range), match.numberOfRanges > 1,
              let r = Range(match.range(at: 1), in: string) else { return nil }
        return String(string[r])
    }

    // MARK: - Company + side lookup

    /// Returns the company for a known contact, or nil when:
    /// - the name is unknown,
    /// - the name is only under "Other" (no company),
    /// - the name appears under two or more different company sections (ambiguous).
    ///
    /// A name appearing under both a company section AND "Other" is treated as
    /// unambiguous (1 distinct company) and returns that company.
    func company(for name: String) -> String? {
        guard let companies = companyIndex[name.lowercased()] else { return nil }
        guard companies.count == 1 else { return nil }   // 0 = Other-only; 2+ = collision
        return companies.first
    }

    /// Returns true when company(for:) is non-nil and non-empty.
    func isCompanyKnown(_ name: String) -> Bool {
        if let c = company(for: name) { return !c.isEmpty }
        return false
    }

    /// Returns the Side for a known contact, or nil on collision.
    func side(for name: String) -> Side? {
        guard let sides = sideIndex[name.lowercased()], sides.count == 1 else { return nil }
        return sides.first
    }

    // MARK: - Fuzzy suggestion (nonisolated static, pure)

    /// Returns contacts that plausibly match `name` based on shared tokens, ranked
    /// by signal strength. Returns [] when `name` is already an exact name/alias hit.
    ///
    /// The static form takes an explicit contact list so it can be called in tests
    /// without touching disk.
    nonisolated static func suggestMatches(for name: String, in contacts: [Contact], limit: Int = 3) -> [Contact] {
        // Fast-path: already an exact match (canonical or alias). Nothing to suggest.
        let nameLower = name.lowercased()
        let isExact = contacts.contains { c in
            c.name.lowercased() == nameLower || c.aliases.contains { $0.lowercased() == nameLower }
        }
        guard !isExact else { return [] }

        // Tokenise a display name for matching. Hyphens become token boundaries so
        // "Wharf-Bulsara" splits to ["wharf", "bulsara"], enabling subset detection
        // across hyphenated surnames.
        func tokens(_ s: String) -> Set<String> {
            let normalised = s.lowercased().replacingOccurrences(of: "-", with: " ")
            return Set(normalised.split(separator: " ").map(String.init).filter { !$0.isEmpty })
        }

        let queryTokens = tokens(name)
        guard !queryTokens.isEmpty else { return [] }

        // Score each contact. Higher = stronger match.
        // 3: query tokens are a subset of contact tokens (covers Wharf <= Wharf-Bulsara)
        // 3: contact tokens are a subset of query tokens (longer name searched shorter)
        // 2: shared surname (last whitespace-split token, pre-hyphen-normalisation)
        // 1: shared first token
        // 0: no signal -> excluded
        let querySurname = String(name.split(separator: " ").last ?? Substring(""))
            .lowercased().replacingOccurrences(of: "-", with: " ")
        let queryFirst = queryTokens.sorted().first ?? ""

        var scored: [(score: Int, contact: Contact)] = []
        for c in contacts {
            let ct = tokens(c.name)
            guard !ct.isEmpty else { continue }

            var score = 0

            // Subset matches (strongest -- catches hyphenated surname family names).
            if queryTokens.isSubset(of: ct) { score = max(score, 3) }
            if ct.isSubset(of: queryTokens) { score = max(score, 3) }

            // Shared surname.
            let cSurname = String(c.name.split(separator: " ").last ?? Substring(""))
                .lowercased().replacingOccurrences(of: "-", with: " ")
            if !querySurname.isEmpty && !cSurname.isEmpty {
                let qSurnameTokens = Set(querySurname.split(separator: " ").map(String.init))
                let cSurnameTokens = Set(cSurname.split(separator: " ").map(String.init))
                if !qSurnameTokens.isDisjoint(with: cSurnameTokens) { score = max(score, 2) }
            }

            // Shared first token.
            let cFirst = ct.sorted().first ?? ""
            if !queryFirst.isEmpty && !cFirst.isEmpty && queryFirst == cFirst { score = max(score, 1) }

            if score > 0 { scored.append((score, c)) }
        }

        // Sort: descending score, then ascending name for determinism.
        let ranked = scored
            .sorted { lhs, rhs in
                lhs.score != rhs.score ? lhs.score > rhs.score : lhs.contact.name < rhs.contact.name
            }
            .prefix(limit)
            .map { $0.contact }

        return Array(ranked)
    }

    /// Instance wrapper: returns ranked contacts plausibly matching `name`.
    /// Returns [] when `name` is already a known exact name or alias.
    func suggestMatches(for name: String, limit: Int = 3) -> [Contact] {
        Self.suggestMatches(for: name, in: contacts, limit: limit)
    }

    // MARK: - Canonical renderer (nonisolated static, pure)

    /// Render a sorted, canonical Markdown representation of the contacts.
    ///
    /// Schema:
    /// - Internal companies: "## <Company>" with bullets sorted by name.
    /// - "## Customers" umbrella with "### <Company>" children, bullets sorted.
    /// - "## Other" with bullets sorted.
    ///
    /// Each bullet: "- **Name** - Title" or "- [Name](linkedin) - Title".
    /// Title omitted (no " - ") when nil/empty.
    nonisolated static func renderCanonical(_ contacts: [Contact]) -> String {
        var lines: [String] = []

        // Partition contacts by side.
        let internalContacts = contacts.filter { $0.side == .internalTeam }
        let customerContacts = contacts.filter { $0.side == .customer }
        let otherContacts    = contacts.filter { $0.side == .other }

        // Internal companies: group -> sort companies -> emit ## heading + sorted bullets.
        let internalByCompany = Dictionary(grouping: internalContacts) { $0.company ?? "Uncategorized" }
        for company in internalByCompany.keys.sorted(by: { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }) {
            let group = internalByCompany[company]!.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            if !lines.isEmpty { lines.append("") }
            lines.append("## \(company)")
            for c in group { lines.append(bulletLine(c)) }
        }

        // Customers: ## Customers umbrella, then ### Company for each customer company.
        if !customerContacts.isEmpty {
            let customerByCompany = Dictionary(grouping: customerContacts) { $0.company ?? "Uncategorized" }
            if !lines.isEmpty { lines.append("") }
            lines.append("## Customers")
            for company in customerByCompany.keys.sorted(by: { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }) {
                let group = customerByCompany[company]!.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                lines.append("")
                lines.append("### \(company)")
                for c in group { lines.append(bulletLine(c)) }
            }
        }

        // Other: ## Other with sorted bullets.
        if !otherContacts.isEmpty {
            let sorted = otherContacts.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            if !lines.isEmpty { lines.append("") }
            lines.append("## Other")
            for c in sorted { lines.append(bulletLine(c)) }
        }

        return lines.joined(separator: "\n")
    }

    /// Build a single canonical bullet line for a contact.
    ///
    /// Format: `- **Name** (aka A, B) - Title`  or `- [Name](url) (aka A, B) - Title`
    /// The `(aka ...)` segment is emitted only when `aliases` is non-empty (sorted for
    /// determinism). Title and aka are both optional.
    nonisolated private static func bulletLine(_ c: Contact) -> String {
        let nameMarkup: String
        if let url = c.linkedin, !url.isEmpty {
            nameMarkup = "[\(c.name)](\(url))"
        } else {
            nameMarkup = "**\(c.name)**"
        }
        let akaSegment: String
        if c.aliases.isEmpty {
            akaSegment = ""
        } else {
            akaSegment = " (aka \(c.aliases.sorted().joined(separator: ", ")))"
        }
        if let title = c.title, !title.isEmpty {
            return "- \(nameMarkup)\(akaSegment) - \(title)"
        } else {
            return "- \(nameMarkup)\(akaSegment)"
        }
    }

    // MARK: - Normalize + dedupe (pure)

    /// Parse `text`, deduplicate contacts, and render canonical Markdown.
    ///
    /// Returns:
    /// - `canonical`: the normalized Markdown ready for review / write-back.
    /// - `report`: a Markdown report with counts, merges, near-dup flags, oddities.
    ///
    /// Dedupe rules (by lowercased/whitespace-trimmed name):
    /// - Exact same name -> merge into the "richest" entry:
    ///   prefer one with linkedin, then non-empty title, then real company over Other/nil.
    ///   If two entries have DIFFERENT real companies, that's a collision: keep one, log it.
    /// - Near-duplicate (same base name + parenthetical like "(London)") -> FLAG only, do not merge.
    /// - Distinct names (e.g. "Christina Wharf" vs "Christina Wharf-Bulsara") -> keep both.
    nonisolated static func normalize(_ text: String) -> (canonical: String, report: String) {
        let contacts = parseContacts(text)

        // ── Step 1: Name-merge ───────────────────────────────────────────────────
        // Group by lowercased name key. Contacts with the same name are merged into
        // one "richest" entry (prefers linkedin > title > real company).
        var nameGroups: [String: [Contact]] = [:]
        var nameGroupOrder: [String] = []
        for c in contacts {
            let key = c.name.lowercased().trimmingCharacters(in: .whitespaces)
            if nameGroups[key] == nil { nameGroupOrder.append(key) }
            nameGroups[key, default: []].append(c)
        }

        var nameDeduped: [Contact] = []
        var mergeReport:     [(name: String, detail: String)] = []
        var collisionReport: [(name: String, detail: String)] = []

        for key in nameGroupOrder {
            let group = nameGroups[key]!
            if group.count == 1 {
                nameDeduped.append(group[0])
            } else {
                let (merged, collision) = mergeGroup(group)
                nameDeduped.append(merged)
                let descriptions = group.map { c -> String in
                    var parts: [String] = []
                    if let co = c.company { parts.append(co) }
                    if let t  = c.title   { parts.append(t) }
                    if c.linkedin != nil  { parts.append("[linkedin]") }
                    return parts.isEmpty ? "(bare)" : parts.joined(separator: ", ")
                }
                if collision {
                    collisionReport.append((merged.name,
                        "company collision: \(descriptions.joined(separator: " | "))"))
                } else {
                    mergeReport.append((merged.name, descriptions.joined(separator: " | ")))
                }
            }
        }

        // ── Step 1b: Alias-merge ─────────────────────────────────────────────────
        // If contact A's canonical name matches any alias of B (or vice versa), they
        // represent the same person under different display names.  Merge them: union
        // alias sets, keep the canonical name from whichever entry is NOT the alias.
        // This runs after name-merge so the groups are already collapsed by identical name.
        var aliasMergeReport: [(name: String, detail: String)] = []
        var aliasMerged: [Contact] = []

        for candidate in nameDeduped {
            var merged = false
            for i in 0..<aliasMerged.count {
                let existing = aliasMerged[i]
                let candidateLower = candidate.name.lowercased()
                let existingLower  = existing.name.lowercased()
                let existingAliasesLower = existing.aliases.map { $0.lowercased() }
                let candidateAliasesLower = candidate.aliases.map { $0.lowercased() }

                let candidateIsAliasOfExisting = existingAliasesLower.contains(candidateLower)
                let existingIsAliasOfCandidate = candidateAliasesLower.contains(existingLower)

                if candidateIsAliasOfExisting || existingIsAliasOfCandidate {
                    // The non-alias entry is canonical.
                    let (canonical, aliasContact) = candidateIsAliasOfExisting
                        ? (existing, candidate)
                        : (candidate, existing)

                    // Union alias sets; include the alias contact's name as a new alias.
                    let allNames = [aliasContact.name] + canonical.aliases + aliasContact.aliases
                    let canonLower = canonical.name.lowercased()
                    var aliasSet = Set<String>()
                    var displayForms: [String: String] = [:]
                    for n in allNames {
                        let low = n.lowercased()
                        if low != canonLower {
                            aliasSet.insert(low)
                            if displayForms[low] == nil { displayForms[low] = n }
                        }
                    }
                    let newAliases = aliasSet.sorted().compactMap { displayForms[$0] }

                    // Merge fields from both (richness: prefer linkedin, title, real company).
                    func richness(_ c: Contact) -> Int {
                        var s = 0
                        if c.linkedin != nil { s += 4 }
                        if c.title    != nil { s += 2 }
                        if c.company  != nil && c.side != .other { s += 1 }
                        return s
                    }
                    let rich = richness(canonical) >= richness(aliasContact) ? canonical : aliasContact
                    let mergedLinkedin = canonical.linkedin ?? aliasContact.linkedin
                    let mergedTitle: String?
                    switch (canonical.title, aliasContact.title) {
                    case (nil, nil):           mergedTitle = nil
                    case (let t?, nil):        mergedTitle = t
                    case (nil, let t?):        mergedTitle = t
                    case (let t1?, let t2?):   mergedTitle = t1.count >= t2.count ? t1 : t2
                    }
                    let mergedCompany = (rich.company != nil && rich.side != .other)
                        ? rich.company : (canonical.company ?? aliasContact.company)
                    let mergedSide = (rich.company != nil && rich.side != .other)
                        ? rich.side : canonical.side

                    var updated = Contact(name: canonical.name, company: mergedCompany,
                                         side: mergedSide, title: mergedTitle,
                                         linkedin: mergedLinkedin)
                    updated.aliases = newAliases
                    aliasMerged[i] = updated
                    aliasMergeReport.append((canonical.name,
                        "alias-merge: \"\(aliasContact.name)\" -> alias of \"\(canonical.name)\""))
                    merged = true
                    break
                }
            }
            if !merged { aliasMerged.append(candidate) }
        }
        nameDeduped = aliasMerged

        // ── Step 2: LinkedIn-merge ───────────────────────────────────────────────
        // Collapse contacts whose LinkedIn URLs normalize to the same key, even when
        // their names differ (e.g. "Tushara Fernando" vs "Tushara Fernando (London)").
        // Only contacts with a non-empty LinkedIn URL participate; nil-linkedin contacts
        // are never grouped together (that would collapse unrelated people).
        //
        // Name preference: choose the name WITHOUT a trailing parenthetical, because
        // the parenthetical is a disambiguation note, not the canonical name.
        // Tiebreak when both lack / both have a parenthetical: pick by richness, then
        // first-seen order (stable, deterministic).
        var linkedinMergeReport: [(name: String, detail: String)] = []
        var linkedinDeduped: [Contact] = []
        var seenLinkedinKeys: [String: Int] = [:]   // key -> index in linkedinDeduped

        for c in nameDeduped {
            guard let url = c.linkedin, !url.isEmpty,
                  let key = normalizedLinkedinKey(url) else {
                // No usable linkedin -> pass through unchanged.
                linkedinDeduped.append(c)
                continue
            }
            if let existingIdx = seenLinkedinKeys[key] {
                // Merge into the existing entry at existingIdx.
                let existing = linkedinDeduped[existingIdx]
                let merged = mergeByLinkedin(existing, c)
                linkedinDeduped[existingIdx] = merged
                linkedinMergeReport.append((
                    merged.name,
                    "linkedin-merge: \"\(existing.name)\" + \"\(c.name)\" -> \"\(merged.name)\""
                ))
            } else {
                seenLinkedinKeys[key] = linkedinDeduped.count
                linkedinDeduped.append(c)
            }
        }
        var deduped = linkedinDeduped

        // ── Step 2b: Explicit Christina Wharf merge ─────────────────────────────
        // "Christina Wharf" (Partnership Director) and "Christina Wharf-Bulsara"
        // (Director of Partner Sales) are the same person.  The generic alias-merge above
        // handles this when the (aka ...) tag is present in Rolodex.md, but until the file
        // is written the two entries are still separate.  This directive collapses them
        // unconditionally (by name, case-insensitive) into one authoritative entry:
        //   canonical name: "Christina Wharf-Bulsara"
        //   alias:          "Christina Wharf"
        //   title:          "Partnership Director"
        //   linkedin:       https://www.linkedin.com/in/christina-wharf-bulsara-1860353b/
        //   company/side:   Intellias / .internalTeam (from whichever entry has it)
        var christinaReport: String? = nil
        let christinaCanonical  = "Christina Wharf-Bulsara"
        let christinaAlias      = "Christina Wharf"
        let christinaLinkedin   = "https://www.linkedin.com/in/christina-wharf-bulsara-1860353b/"
        let christinaTitle      = "Partnership Director"

        let wharfIdx    = deduped.firstIndex { $0.name.caseInsensitiveCompare(christinaAlias)     == .orderedSame }
        let bulsaraIdx  = deduped.firstIndex { $0.name.caseInsensitiveCompare(christinaCanonical) == .orderedSame }

        if wharfIdx != nil || bulsaraIdx != nil {
            // Determine the section affiliation from whichever entry has Intellias (or any).
            let sample = (wharfIdx.map { deduped[$0] } ?? bulsaraIdx.map { deduped[$0] })!
            let mergedCompany = sample.company ?? "Intellias"
            let mergedSide    = (sample.side != .other) ? sample.side : Side.internalTeam

            var authoritative = Contact(name: christinaCanonical,
                                        company: mergedCompany,
                                        side: mergedSide,
                                        title: christinaTitle,
                                        linkedin: christinaLinkedin)
            authoritative.aliases = [christinaAlias]

            // Remove both entries (descending index order to keep indices stable).
            var toRemove = [wharfIdx, bulsaraIdx].compactMap { $0 }
            toRemove = Array(Set(toRemove)).sorted(by: >)
            for idx in toRemove { deduped.remove(at: idx) }
            deduped.append(authoritative)
            christinaReport = "explicit-merge: \"\(christinaAlias)\" + \"\(christinaCanonical)\" -> \"\(christinaCanonical)\""
        }

        // ── Step 3: Drop the "Dubhashi" Other fragment ──────────────────────────
        // This is the orphaned mis-typed surname of Addy Dubhash (Other section,
        // name exactly "Dubhashi"). Targeted explicit drop — no fuzzy logic.
        var droppedNames: [String] = []
        deduped = deduped.filter { c in
            let isOrphan = c.name.trimmingCharacters(in: .whitespaces)
                            .caseInsensitiveCompare("Dubhashi") == .orderedSame
            if isOrphan { droppedNames.append(c.name) }
            return !isOrphan
        }

        // ── Step 4: Title rewrites (rules 3 + 4) ────────────────────────────────
        // Rule 3: strip redundant company suffix from title.
        //   "Head of Revenue Operations, IG Group" under IG Group -> "Head of Revenue Operations"
        //   Only when the trailing ", <X>" equals the contact's own section company (case-insensitive).
        //   Does NOT strip when the company in the title differs from the section.
        // Rule 4: if the remaining title (after rule 3) equals the section company, blank it.
        //   "AWS" under AWS -> nil title.
        deduped = deduped.map { c in
            guard let rawTitle = c.title, let sectionCompany = c.company else { return c }
            var title = rawTitle

            // Rule 3: strip ", <SectionCompany>" suffix.
            let suffix = ", \(sectionCompany)"
            if title.lowercased().hasSuffix(suffix.lowercased()) {
                title = String(title.dropLast(suffix.count))
                    .trimmingCharacters(in: .whitespaces)
            }

            // Rule 4: blank title that equals section company.
            if title.trimmingCharacters(in: .whitespaces)
                   .caseInsensitiveCompare(sectionCompany) == .orderedSame {
                title = ""
            }

            let newTitle: String? = title.isEmpty ? nil : title
            guard newTitle != c.title else { return c }
            var updated = Contact(name: c.name, company: c.company, side: c.side,
                                  title: newTitle, linkedin: c.linkedin)
            updated.aliases = c.aliases
            return updated
        }

        // ── Step 5: Near-duplicate detection ────────────────────────────────────
        // Runs AFTER linkedin-merge so merged pairs aren't double-reported.
        var nearDups: [(a: String, b: String)] = []
        let allNames = deduped.map { $0.name }
        for i in 0..<allNames.count {
            for j in (i+1)..<allNames.count {
                if isNearDuplicate(allNames[i], allNames[j]) {
                    nearDups.append((allNames[i], allNames[j]))
                }
            }
        }

        // ── Oddity detection: scan raw lines ─────────────────────────────────────
        // Runs against the original text, before the parser cleans stray chars / empty roles.
        var oddities: [String] = []
        let rawBulletPattern = try? NSRegularExpression(pattern: #"^\s*-\s+"#)
        for rawLine in text.components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let nsRange = NSRange(trimmed.startIndex..., in: trimmed)
            guard rawBulletPattern?.firstMatch(in: trimmed, range: nsRange) != nil else { continue }

            // Pattern 1: stray non-space char immediately after link closing paren, e.g. ")i".
            if let strayRegex = try? NSRegularExpression(pattern: #"\]\([^)]+\)[^\s\-\n]"#) {
                if strayRegex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) != nil {
                    oddities.append("Stray chars after link URL: \"\(trimmed)\"")
                }
            }

            // Pattern 2: bullet ends with " -" = empty role (e.g. "- MORISCO -" after trim).
            if trimmed.hasSuffix(" -") {
                let body = trimmed.drop(while: { $0 == "-" || $0 == " " })
                if !body.isEmpty {
                    oddities.append("Empty role (trailing separator): \"\(trimmed)\"")
                }
            }
        }

        let canonical = renderCanonical(deduped)

        // ── Stats ────────────────────────────────────────────────────────────────
        let inCount     = contacts.count
        let outCount    = deduped.count
        let internalOut = deduped.filter { $0.side == .internalTeam }.count
        let customerOut = deduped.filter { $0.side == .customer }.count
        let otherOut    = deduped.filter { $0.side == .other }.count

        // ── Report ───────────────────────────────────────────────────────────────
        var reportLines: [String] = []
        reportLines.append("# Rolodex Normalization Report")
        reportLines.append("")
        reportLines.append("## Counts")
        reportLines.append("- Input contacts: \(inCount)")
        reportLines.append("- Output contacts (after dedupe): \(outCount)")
        reportLines.append("- Merged: \(inCount - outCount)")
        reportLines.append("- Internal: \(internalOut), Customer: \(customerOut), Other: \(otherOut)")

        if !mergeReport.isEmpty {
            reportLines.append("")
            reportLines.append("## Merges performed (same name)")
            for m in mergeReport {
                reportLines.append("- **\(m.name)**: \(m.detail)")
            }
        }

        if !aliasMergeReport.isEmpty {
            reportLines.append("")
            reportLines.append("## Merges performed (alias match)")
            for m in aliasMergeReport {
                reportLines.append("- **\(m.name)**: \(m.detail)")
            }
        }

        if !linkedinMergeReport.isEmpty {
            reportLines.append("")
            reportLines.append("## Merges performed (same LinkedIn URL)")
            for m in linkedinMergeReport {
                reportLines.append("- **\(m.name)**: \(m.detail)")
            }
        }

        if let cr = christinaReport {
            reportLines.append("")
            reportLines.append("## Explicit person merges")
            reportLines.append("- **\(christinaCanonical)**: \(cr)")
        }

        if !collisionReport.isEmpty {
            reportLines.append("")
            reportLines.append("## Company collisions (manual review needed)")
            for m in collisionReport {
                reportLines.append("- **\(m.name)**: \(m.detail)")
            }
        }

        if !droppedNames.isEmpty {
            reportLines.append("")
            reportLines.append("## Explicit drops")
            for n in droppedNames {
                reportLines.append("- Dropped orphan entry: \"\(n)\" (mis-typed surname fragment)")
            }
        }

        if !nearDups.isEmpty {
            reportLines.append("")
            reportLines.append("## Near-duplicate names (NOT merged -- manual review)")
            for nd in nearDups {
                reportLines.append("- \"\(nd.a)\" vs \"\(nd.b)\"")
            }
        }

        if !oddities.isEmpty {
            reportLines.append("")
            reportLines.append("## Oddities flagged")
            for o in oddities {
                reportLines.append("- \(o)")
            }
        }

        let report = reportLines.joined(separator: "\n")
        return (canonical, report)
    }

    /// Normalize a LinkedIn URL to a stable deduplication key.
    ///
    /// Returns nil when the URL is empty, which prevents nil-linkedin contacts from
    /// being grouped together (that would collapse unrelated people).
    ///
    /// Normalization: lowercase, strip scheme (http/https), strip leading "www.",
    /// strip trailing slash.
    nonisolated private static func normalizedLinkedinKey(_ url: String) -> String? {
        var s = url.lowercased().trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        // Strip scheme.
        for scheme in ["https://", "http://"] {
            if s.hasPrefix(scheme) { s = String(s.dropFirst(scheme.count)); break }
        }
        // Strip leading www.
        if s.hasPrefix("www.") { s = String(s.dropFirst(4)) }
        // Strip trailing slash.
        if s.hasSuffix("/") { s = String(s.dropLast()) }
        return s.isEmpty ? nil : s
    }

    /// Merge two contacts that share the same LinkedIn URL.
    ///
    /// Name preference: the name WITHOUT a trailing parenthetical (e.g. "Tushara Fernando"
    /// over "Tushara Fernando (London)"). Tiebreak: richness score, then `a` (first-seen).
    /// Title: richest non-nil (longer, as a proxy for more specific).
    nonisolated private static func mergeByLinkedin(_ a: Contact, _ b: Contact) -> Contact {
        // Choose the name without a parenthetical suffix when one has it and the other doesn't.
        func hasParenthetical(_ name: String) -> Bool {
            name.trimmingCharacters(in: .whitespaces).hasSuffix(")")
            && name.contains("(")
        }
        let chosenName: String
        switch (hasParenthetical(a.name), hasParenthetical(b.name)) {
        case (true,  false): chosenName = b.name
        case (false, true):  chosenName = a.name
        default:
            // Both or neither have a parenthetical: pick by richness, then first-seen (a).
            func richness(_ c: Contact) -> Int {
                var s = 0
                if c.linkedin != nil { s += 4 }
                if c.title    != nil { s += 2 }
                if c.company  != nil && c.side != .other { s += 1 }
                return s
            }
            chosenName = richness(a) >= richness(b) ? a.name : b.name
        }

        // Merge fields: prefer non-nil, and when both are non-nil prefer the longer title.
        let mergedTitle: String?
        switch (a.title, b.title) {
        case (nil, nil):       mergedTitle = nil
        case (let t?, nil):    mergedTitle = t
        case (nil, let t?):    mergedTitle = t
        case (let t1?, let t2?): mergedTitle = t1.count >= t2.count ? t1 : t2
        }

        let mergedCompany = (a.company != nil && a.side != .other) ? a.company : b.company
        let mergedSide    = (a.company != nil && a.side != .other) ? a.side    : b.side
        let mergedLinkedin = a.linkedin ?? b.linkedin

        // Union alias sets from both entries (case-insensitive dedup; exclude canonical name).
        let canonicalLower = chosenName.lowercased()
        var aliasSet = Set<String>()
        for alias in (a.aliases + b.aliases) {
            let low = alias.lowercased()
            if low != canonicalLower { aliasSet.insert(low) }
        }
        // Prefer display form from a; if a doesn't have it try b; else use lowercase key.
        let allForms = (a.aliases + b.aliases).filter { $0.lowercased() != canonicalLower }
        let mergedAliases = aliasSet.sorted().map { key -> String in
            allForms.first { $0.lowercased() == key } ?? key
        }.sorted()

        var result = Contact(name: chosenName, company: mergedCompany, side: mergedSide,
                             title: mergedTitle, linkedin: mergedLinkedin)
        result.aliases = mergedAliases
        return result
    }

    /// Merge a group of contacts with the same normalized name.
    /// Returns (merged: Contact, collision: Bool).
    /// `collision` is true when two entries have DIFFERENT real companies.
    nonisolated private static func mergeGroup(_ group: [Contact]) -> (Contact, Bool) {
        // Separate entries with a real (non-nil, non-other) company from others.
        let withRealCompany = group.filter { $0.company != nil && $0.side != .other }
        let realCompanies = Set(withRealCompany.compactMap { $0.company })

        let collision = realCompanies.count >= 2

        // Pick the richest entry as the base:
        // 1. Prefer one with linkedin.
        // 2. Prefer one with a non-nil title.
        // 3. Prefer one with a real company.
        // 4. Otherwise first in group.
        func richness(_ c: Contact) -> Int {
            var score = 0
            if c.linkedin != nil { score += 4 }
            if c.title != nil { score += 2 }
            if c.company != nil && c.side != .other { score += 1 }
            return score
        }

        let base = group.max(by: { richness($0) < richness($1) })!

        // Merge fields: take from base, fill blanks from others.
        var mergedLinkedin = base.linkedin
        var mergedTitle    = base.title
        var mergedCompany  = base.company
        var mergedSide     = base.side

        for c in group {
            if mergedLinkedin == nil, let url = c.linkedin { mergedLinkedin = url }
            if mergedTitle == nil, let t = c.title { mergedTitle = t }
            if (mergedCompany == nil || mergedSide == .other), c.company != nil, c.side != .other {
                mergedCompany = c.company
                mergedSide    = c.side
            }
        }

        // Union alias sets from all group members (case-insensitive dedup; exclude canonical).
        let baseLower = base.name.lowercased()
        var aliasSet = Set<String>()
        let allForms = group.flatMap { $0.aliases }
        for alias in allForms {
            let low = alias.lowercased()
            if low != baseLower { aliasSet.insert(low) }
        }
        let mergedAliases = aliasSet.sorted().map { key -> String in
            allForms.first { $0.lowercased() == key } ?? key
        }.sorted()

        var merged = Contact(
            name: base.name,
            company: mergedCompany,
            side: mergedSide,
            title: mergedTitle,
            linkedin: mergedLinkedin
        )
        merged.aliases = mergedAliases
        return (merged, collision)
    }

    /// Two names are "near-duplicates" if one is the other with a parenthetical suffix appended.
    /// E.g. "Tushara Fernando" vs "Tushara Fernando (London)".
    ///
    /// Requires that the longer name STARTS WITH the shorter name (case-insensitive prefix),
    /// then a space and a parenthetical "(...)". This prevents false positives where two
    /// unrelated names happen to share a character-count relationship.
    nonisolated private static func isNearDuplicate(_ a: String, _ b: String) -> Bool {
        let shorter = a.count <= b.count ? a : b
        let longer  = a.count <= b.count ? b : a
        guard longer.count > shorter.count else { return false }
        // The longer name must start with the shorter name (case-insensitive).
        guard longer.lowercased().hasPrefix(shorter.lowercased()) else { return false }
        // The remainder after the prefix must be a parenthetical "(...)".
        let suffix = longer.dropFirst(shorter.count).trimmingCharacters(in: .whitespaces)
        return suffix.hasPrefix("(") && suffix.hasSuffix(")")
    }

    // MARK: - normalizeContacts (instance method -- reads/writes disk)

    /// Produce a canonical preview (dry-run) or overwrite the contacts file.
    ///
    /// - dryRun: if true, writes preview files only; NEVER touches Rolodex.md.
    /// - stamp: a timestamp string used to name the backup file, e.g. "20260612-143025".
    ///
    /// Files written:
    /// - Always: Rolodex.backup-<stamp>.md (backup of the original, same dir)
    /// - dryRun == true: Rolodex.normalized.md + Rolodex.normalize-report.md (same dir)
    /// - dryRun == false: Rolodex.md overwritten with canonical; then refresh().
    func normalizeContacts(dryRun: Bool, stamp: String) {
        let url = settings.contactsURL
        let dir = url.deletingLastPathComponent()

        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            AppLog.log("normalizeContacts: could not read \(url.lastPathComponent)", category: "vault")
            return
        }

        // Always write a backup of the original.
        let backupURL = dir.appendingPathComponent("Rolodex.backup-\(stamp).md")
        try? text.write(to: backupURL, atomically: true, encoding: .utf8)
        AppLog.log("normalizeContacts: backup written to \(backupURL.lastPathComponent)", category: "vault")

        let (canonical, report) = Self.normalize(text)

        if dryRun {
            let previewURL = dir.appendingPathComponent("Rolodex.normalized.md")
            let reportURL  = dir.appendingPathComponent("Rolodex.normalize-report.md")
            try? canonical.write(to: previewURL, atomically: true, encoding: .utf8)
            try? report.write(to: reportURL, atomically: true, encoding: .utf8)
            AppLog.log("normalizeContacts: dry-run preview written to \(previewURL.lastPathComponent) + \(reportURL.lastPathComponent)", category: "vault")
        } else {
            try? canonical.write(to: url, atomically: true, encoding: .utf8)
            AppLog.log("normalizeContacts: \(url.lastPathComponent) overwritten with canonical", category: "vault")
            refreshAfterMutation()
        }
    }

    // MARK: One-time contacts-file rename (Key People.md -> Rolodex.md)

    private func migrateContactsFileIfNeeded() {
        let fm = FileManager.default
        let target = settings.contactsURL
        let legacy = settings.legacyContactsURL
        guard !fm.fileExists(atPath: target.path),
              fm.fileExists(atPath: legacy.path),
              target.lastPathComponent != legacy.lastPathComponent else { return }
        do {
            try fm.moveItem(at: legacy, to: target)
            AppLog.log("Migrated \(legacy.lastPathComponent) to \(target.lastPathComponent)", category: "vault")
        } catch {
            AppLog.log("Contacts migration failed: \(error.localizedDescription)", category: "vault")
        }
    }

    // MARK: Destinations (folder tree)

    private func loadDestinations() -> [VaultDestination] {
        Self.loadDestinations(vaultURL: settings.vaultURL, scanRoots: settings.scanRoots)
    }

    nonisolated private static func loadDestinations(
        vaultURL: URL, scanRoots: [String]
    ) -> [VaultDestination] {
        var result: [VaultDestination] = []
        let fm = FileManager.default
        for root in scanRoots {
            let rootURL = vaultURL.appendingPathComponent(root, isDirectory: true)
            guard fm.fileExists(atPath: rootURL.path) else { continue }
            walk(rootURL, relative: root, depth: 0, into: &result)
        }
        return result.sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
    }

    nonisolated private static func walk(
        _ url: URL, relative: String, depth: Int, into result: inout [VaultDestination]
    ) {
        guard depth < maxDepth else { return }
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return }

        for item in items {
            guard (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let name = item.lastPathComponent
            if excludedNames.contains(name) || isStatusFolder(name) { continue }
            let relPath = relative + "/" + name
            result.append(VaultDestination(path: relPath))
            walk(item, relative: relPath, depth: depth + 1, into: &result)
        }
    }

    /// Pipeline-status groupers like "00 - Thesis Validation" are not destinations.
    nonisolated private static func isStatusFolder(_ name: String) -> Bool {
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

    /// Appends not-yet-known people (bare names from the attendee list -- no company
    /// or title) under the "Other" section. Uses parse->mutate->render so the output
    /// is always canonical. Names already known by canonical name OR any alias are skipped.
    func addPeople(_ rawNames: [String]) {
        let url = settings.contactsURL
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        var parsed = Self.parseContacts(text)

        // Build a set of all known names + aliases for fast skip-check.
        var knownLower = Set<String>()
        for c in parsed {
            knownLower.insert(c.name.lowercased())
            for alias in c.aliases { knownLower.insert(alias.lowercased()) }
        }

        let fresh = rawNames
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !knownLower.contains($0.lowercased()) }
        guard !fresh.isEmpty else { return }

        for name in fresh {
            parsed.append(Contact(name: name, company: nil, side: .other,
                                  title: nil, linkedin: nil))
        }

        let rendered = Self.renderCanonical(parsed)
        writeContacts(rendered, to: url)
        AppLog.log("Added \(fresh.count) contacts under \(Self.otherSection) in \(url.lastPathComponent)", category: "vault")
        refreshAfterMutation()
    }

    /// Adds a single rich contact. Delegates to upsertPerson for dedup safety.
    func addPerson(name rawName: String, title rawTitle: String, company rawCompany: String, linkedin rawLink: String) {
        upsertPerson(name: rawName, title: rawTitle, company: rawCompany, linkedin: rawLink)
    }

    /// Delete Rolodex contacts by display name (case-insensitive, matched on the canonical
    /// name). Used by the People tab to purge polluted/junk entries — e.g. speaker-split
    /// "Rosen"/"Adam" fragments that leaked in via `addPeople`. Removes ONLY the contact
    /// record; a voiceprint enrolled for the same name is left untouched. No-op when nothing
    /// matches, so a stray call can't rewrite the file needlessly. Returns the count removed.
    @discardableResult
    func removePeople(_ rawNames: [String]) -> Int {
        let targets = Set(rawNames
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty })
        guard !targets.isEmpty else { return 0 }

        let url = settings.contactsURL
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let parsed = Self.parseContacts(text)
        let kept = parsed.filter { !targets.contains($0.name.lowercased()) }
        let removed = parsed.count - kept.count
        guard removed > 0 else { return 0 }

        writeContacts(Self.renderCanonical(kept), to: url)
        AppLog.log("Removed \(removed) contact(s) from \(url.lastPathComponent)", category: "vault")
        refreshAfterMutation()
        return removed
    }

    /// Idempotent relocate/insert for a rich contact entry using parse->mutate->render.
    ///
    /// Algorithm:
    /// 1. Parse current file into [Contact].
    /// 2. Find any existing contact matched by canonical name OR alias (case-insensitive).
    ///    When matched by alias: preserve the canonical name, merge aliases + linkedin rather
    ///    than overwriting with the alias string -- avoids silent data loss.
    ///    When matched by canonical name: replace with new data.
    /// 3. Determine side: when `explicitSide` is non-nil use it directly (editor explicit
    ///    placement); otherwise derive from company (inherit existing / brand-new -> .customer
    ///    / empty company -> .other).
    ///    Guard: empty company always forces .other regardless of explicitSide, so we never
    ///    emit a ## Uncategorized internal section or a ## Customers entry with no company.
    /// 4. renderCanonical -> write -> refresh.
    ///
    /// - Parameters:
    ///   - side: When non-nil, use this placement instead of the company-derived default.
    ///           Nil preserves the existing inference behaviour for all pre-editor callers.
    /// When `clearLinkedinIfEmpty` is `true` AND the passed `linkedin` field is empty,
    /// the contact is written with NO linkedin URL (clears an existing one). When
    /// `false` (the default, used by all enrichment/inferred paths), an empty `linkedin`
    /// preserves whatever was already stored -- the historical preserve-on-empty behaviour.
    func upsertPerson(name rawName: String, title rawTitle: String, company rawCompany: String,
                      linkedin rawLink: String, side explicitSide: Side? = nil,
                      clearLinkedinIfEmpty: Bool = false) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let titleTrimmed = rawTitle.trimmingCharacters(in: .whitespaces)
        let companyTrimmed = rawCompany.trimmingCharacters(in: .whitespaces)
        let linkTrimmed = rawLink.trimmingCharacters(in: .whitespaces)
        let title: String? = titleTrimmed.isEmpty ? nil : titleTrimmed
        let company: String? = companyTrimmed.isEmpty ? nil : companyTrimmed
        let link: String? = linkTrimmed.isEmpty ? nil : linkTrimmed

        let url = settings.contactsURL
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        var parsed = Self.parseContacts(text)

        // Determine side.
        // - Empty company always -> .other (guards against junk ## Uncategorized sections).
        // - Explicit side overrides derivation when company is present.
        // - Otherwise inherit from existing contacts for that company.
        let side: Side
        if company == nil {
            side = .other
        } else if let explicit = explicitSide {
            side = explicit
        } else {
            side = Self.sideFor(company: company!, in: parsed)
        }

        // Build the title string: "Title, Company" or just "Title" when company is nil.
        let titleStr: String?
        if let t = title, let co = company {
            titleStr = "\(t), \(co)"
        } else if let t = title {
            titleStr = t
        } else if let co = company {
            titleStr = co
        } else {
            titleStr = nil
        }

        let nameLower = name.lowercased()

        // Find an existing match by canonical name or alias.
        if let existingIdx = parsed.firstIndex(where: { c in
            c.name.lowercased() == nameLower ||
            c.aliases.contains(where: { $0.lowercased() == nameLower })
        }) {
            let existing = parsed[existingIdx]
            let matchedByAlias = existing.name.lowercased() != nameLower

            if matchedByAlias {
                // Preserve the canonical name + existing aliases; only update
                // title/company/linkedin with the new data.
                let aliasLink = (clearLinkedinIfEmpty && link == nil) ? nil : (link ?? existing.linkedin)
                var merged = Contact(name: existing.name, company: company, side: side,
                                     title: titleStr, linkedin: aliasLink)
                merged.aliases = existing.aliases
                parsed[existingIdx] = merged
            } else {
                // Matched by canonical name: replace, but preserve any existing aliases
                // and linkedin if not provided.
                let existingAliases = existing.aliases
                let resolvedLink = (clearLinkedinIfEmpty && link == nil) ? nil : (link ?? existing.linkedin)
                var updated = Contact(name: name, company: company, side: side,
                                      title: titleStr, linkedin: resolvedLink)
                updated.aliases = existingAliases
                parsed[existingIdx] = updated
            }
        } else {
            // No existing entry: insert new contact.
            var newContact = Contact(name: name, company: company, side: side,
                                     title: titleStr, linkedin: link)
            newContact.aliases = []
            parsed.append(newContact)
        }

        let rendered = Self.renderCanonical(parsed)
        writeContacts(rendered, to: url)
        let section = company ?? Self.otherSection
        AppLog.log("Upserted contact \(name) under \(section) in \(url.lastPathComponent)", category: "vault")
        refreshAfterMutation()
    }

    /// Rename a contact in place, preserving all fields (aliases, company, side, title, linkedin).
    ///
    /// Matches by canonical name OR alias (case-insensitive). When the target name matches
    /// one of the contact's own aliases, that alias is removed from the aliases list so the
    /// canonical name and alias do not collide.
    ///
    /// When `newName` already exists as a separate contact (a collision), the two entries are
    /// merged using the same richness rules as normalize() -- richer fields win, alias sets
    /// are unioned -- and the result is logged.
    ///
    /// No-op when `oldName` is not found in the file.
    func renameContact(from oldName: String, to newName: String) {
        let oldTrimmed = oldName.trimmingCharacters(in: .whitespacesAndNewlines)
        let newTrimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !oldTrimmed.isEmpty, !newTrimmed.isEmpty else { return }
        guard oldTrimmed.lowercased() != newTrimmed.lowercased() else { return }

        let url = settings.contactsURL
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        var parsed = Self.parseContacts(text)

        let oldLower = oldTrimmed.lowercased()
        let newLower = newTrimmed.lowercased()

        // Find the contact to rename.
        guard let sourceIdx = parsed.firstIndex(where: { c in
            c.name.lowercased() == oldLower ||
            c.aliases.contains(where: { $0.lowercased() == oldLower })
        }) else {
            AppLog.log("renameContact: no contact found matching \"\(oldTrimmed)\"", category: "vault")
            return
        }

        var renamed = parsed[sourceIdx]
        renamed = Contact(name: newTrimmed, company: renamed.company, side: renamed.side,
                          title: renamed.title, linkedin: renamed.linkedin)
        // Preserve aliases; drop any alias that now matches the new canonical name (avoid redundant aka).
        let filteredAliases = parsed[sourceIdx].aliases.filter { $0.lowercased() != newLower }
        renamed.aliases = filteredAliases

        // Remove the source entry.
        parsed.remove(at: sourceIdx)

        // Check for a collision: another contact already has newName as canonical or alias.
        if let collisionIdx = parsed.firstIndex(where: { c in
            c.name.lowercased() == newLower ||
            c.aliases.contains(where: { $0.lowercased() == newLower })
        }) {
            let collision = parsed[collisionIdx]
            AppLog.log("renameContact: collision -- \"\(newTrimmed)\" already exists; merging", category: "vault")
            let merged = Self.mergeRenameCollision(renamed, collision)
            parsed[collisionIdx] = merged
        } else {
            parsed.append(renamed)
        }

        let rendered = Self.renderCanonical(parsed)
        writeContacts(rendered, to: url)
        AppLog.log("renameContact: \"\(oldTrimmed)\" -> \"\(newTrimmed)\" in \(url.lastPathComponent)", category: "vault")
        refreshAfterMutation()
    }

    /// Merge two contacts that collided on a rename, preferring the richer entry.
    /// Richness: linkedin > title > real company. Alias sets are unioned.
    nonisolated private static func mergeRenameCollision(_ a: Contact, _ b: Contact) -> Contact {
        func richness(_ c: Contact) -> Int {
            var s = 0
            if c.linkedin != nil { s += 4 }
            if c.title    != nil { s += 2 }
            if c.company  != nil && c.side != .other { s += 1 }
            return s
        }
        let rich = richness(a) >= richness(b) ? a : b
        let other = richness(a) >= richness(b) ? b : a

        let mergedLinkedin = rich.linkedin ?? other.linkedin
        let mergedTitle: String?
        switch (rich.title, other.title) {
        case (nil, nil):          mergedTitle = nil
        case (let t?, nil):       mergedTitle = t
        case (nil, let t?):       mergedTitle = t
        case (let t1?, let t2?):  mergedTitle = t1.count >= t2.count ? t1 : t2
        }
        let mergedCompany = (rich.company != nil && rich.side != .other) ? rich.company : other.company
        let mergedSide    = (rich.company != nil && rich.side != .other) ? rich.side    : other.side

        let canonLower = rich.name.lowercased()
        var aliasSet = Set<String>()
        for alias in (a.aliases + b.aliases) {
            let low = alias.lowercased()
            if low != canonLower { aliasSet.insert(low) }
        }
        let allForms = (a.aliases + b.aliases)
        let mergedAliases = aliasSet.sorted().map { key -> String in
            allForms.first { $0.lowercased() == key } ?? key
        }

        var result = Contact(name: rich.name, company: mergedCompany, side: mergedSide,
                             title: mergedTitle, linkedin: mergedLinkedin)
        result.aliases = mergedAliases
        return result
    }

    /// Returns the `Side` to use for a given company name, consulting the existing
    /// parsed contacts. The first contact whose company ci-matches determines the side.
    /// If no match is found, returns `.customer` (new external company is the safe default).
    nonisolated private static func sideFor(company: String, in contacts: [Contact]) -> Side {
        for c in contacts {
            if let co = c.company, co.caseInsensitiveCompare(company) == .orderedSame {
                return c.side
            }
        }
        return .customer  // brand-new company: assume external attendee
    }

    /// Add `alias` to the `(aka ...)` set of the bullet whose canonical name is
    /// `canonicalName` (case-insensitive match). If the alias is already present (ci),
    /// or equals the canonical name itself, the call is a no-op.
    ///
    /// The line is rewritten in place (one-line surgery, not a full reparse/render of
    /// the file) to preserve all other content in the contacts file unchanged.
    ///
    /// After writing, `refresh()` is called so the index is up-to-date.
    func addAlias(_ alias: String, toCanonical canonicalName: String) {
        let alias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        let canonicalName = canonicalName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !alias.isEmpty, !canonicalName.isEmpty else { return }
        guard alias.lowercased() != canonicalName.lowercased() else { return }

        let url = settings.contactsURL
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        var lines = text.components(separatedBy: "\n")

        // Find the bullet line for this canonical name.
        guard let idx = lines.firstIndex(where: { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("-") else { return false }
            return Self.extractName(from: trimmed)?.lowercased() == canonicalName.lowercased()
        }) else { return }

        // Parse the current aliases on that line.
        let (_, existingTitle, existingLinkedin, existingAliases) = Self.extractBulletFields(lines[idx])

        // Idempotency: no-op if alias already present.
        if existingAliases.contains(where: { $0.lowercased() == alias.lowercased() }) { return }

        // Build updated alias list (sorted).
        let newAliases = (existingAliases + [alias]).sorted()

        // Rebuild the contact with the updated aliases and rewrite the line in place.
        // Note: this canonicalizes the name markup (bold or link) for that one bullet.
        var updated = Contact(name: canonicalName, company: nil, side: .other,
                              title: existingTitle, linkedin: existingLinkedin)
        updated.aliases = newAliases
        let newLine = Self.bulletLine(updated)
        lines[idx] = newLine

        writeContacts(lines, to: url)
        AppLog.log("addAlias: added alias \"\(alias)\" to \"\(canonicalName)\" in \(url.lastPathComponent)", category: "vault")
        refreshAfterMutation()
    }

    /// Insert a contact bullet directly under a plain-text section header, creating
    /// the section at the end of the file if it's missing. Bullets are written at
    /// column 0 (no leading whitespace) so Markdown renders a list, not a code block.
    private func insertContact(_ entry: String, under section: String, in lines: inout [String]) {
        if let idx = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(section) == .orderedSame
        }) {
            lines.insert(entry, at: idx + 1)
        } else {
            if let last = lines.last, !last.trimmingCharacters(in: .whitespaces).isEmpty { lines.append("") }
            lines.append(section)
            lines.append(entry)
        }
    }

    private func writeContacts(_ lines: [String], to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func writeContacts(_ text: String, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    nonisolated private static func loadFileCustomers(contacts: [Contact]) -> [String] {
        // Derive customer companies from the side index.
        var seen = Set<String>()
        var result: [String] = []
        for c in contacts where c.side == .customer {
            guard let company = c.company else { continue }
            if seen.insert(company.lowercased()).inserted { result.append(company) }
        }
        return result.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    // MARK: Reconciliation (Customers folders <-> contacts file)

    /// Customer leaf names -- destinations whose parent folder is "Customers".
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

    // MARK: Reconciliation helpers (renamed from "normalize" to avoid overload collision)

    private static func collapsedKey(_ s: String) -> String {
        s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }
    private static func areNear(_ a: String, _ b: String) -> Bool {
        let na = collapsedKey(a), nb = collapsedKey(b)
        guard !na.isEmpty, !nb.isEmpty else { return false }
        if na == nb { return true }
        if na.count > 3, nb.count > 3, (na.contains(nb) || nb.contains(na)) { return true }
        return min(na.count, nb.count) > 3 && levenshtein(na, nb) <= 2
    }
    private static func nearReason(_ folder: String, _ file: String) -> String {
        let nf = collapsedKey(folder), ff = collapsedKey(file)
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
