import Foundation

/// Shared title/company suffix rules for roles and Rolodex projection.
enum PersonTitleFormatting {
    /// Strip trailing ", <company>" from a stored title; bare-company titles become "".
    static func strippedTitle(_ raw: String?, company: String?) -> String {
        guard let raw, let co = company, !co.isEmpty else { return raw ?? "" }
        if raw.caseInsensitiveCompare(co) == .orderedSame { return "" }
        let suffix = ", \(co)"
        if raw.lowercased().hasSuffix(suffix.lowercased()) {
            return String(raw.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
        }
        return raw
    }

    /// Bake title the way Contact / Rolodex expect: "Title, Company" or company-only.
    static func bakedTitle(title: String?, company: String?) -> String? {
        let t = title?.trimmingCharacters(in: .whitespaces) ?? ""
        let co = company?.trimmingCharacters(in: .whitespaces) ?? ""
        if !t.isEmpty && !co.isEmpty { return "\(t), \(co)" }
        if !t.isEmpty { return t }
        if !co.isEmpty { return co }
        return nil
    }
}
