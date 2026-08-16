import Foundation

/// Versioned JSON export/import for terminology + people.
enum KnowledgeExportImport {
    static let currentVersion = 2

    struct Payload: Codable {
        var version: Int
        var exportedAt: Date
        var terminology: [TerminologyEntry]
        var people: [PersonRecord]
    }

    /// v1 export shape — flat title/company on the person row.
    private struct LegacyPersonRecord: Codable {
        let id: String
        var name: String
        var company: String?
        var side: Side
        var title: String?
        var linkedin: String?
        var aliases: [String]
        let createdAt: Date
        var updatedAt: Date
    }

    private struct LegacyPayload: Codable {
        var version: Int
        var exportedAt: Date
        var terminology: [TerminologyEntry]
        var people: [LegacyPersonRecord]
    }

    static func exportJSON(terminology: TerminologyStore = TerminologyStore(),
                           people: PeopleStore = PeopleStore()) throws -> Data {
        let payload = Payload(
            version: currentVersion,
            exportedAt: Date(),
            terminology: terminology.all(),
            people: people.all()
        )
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return try enc.encode(payload)
    }

    static func importJSON(_ data: Data,
                           terminology: TerminologyStore = TerminologyStore(),
                           people: PeopleStore = PeopleStore()) throws {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601

        if let payload = try? dec.decode(Payload.self, from: data) {
            guard payload.version == currentVersion else {
                throw ImportError.unsupportedVersion(payload.version)
            }
            for entry in payload.terminology {
                terminology.upsert(from: entry.fromText, to: entry.toText, notes: entry.notes,
                                   source: entry.source, scope: entry.scope)
            }
            people.replaceAll(records: payload.people)
            return
        }

        let legacy = try dec.decode(LegacyPayload.self, from: data)
        guard legacy.version == 1 else {
            throw ImportError.unsupportedVersion(legacy.version)
        }
        for entry in legacy.terminology {
            terminology.upsert(from: entry.fromText, to: entry.toText, notes: entry.notes,
                               source: entry.source, scope: entry.scope)
        }
        let contacts = legacy.people.map { legacy -> Contact in
            Contact(name: legacy.name, company: legacy.company, side: legacy.side,
                    title: legacy.title, linkedin: legacy.linkedin, aliases: legacy.aliases)
        }
        people.replaceAll(contacts: contacts)
    }

    enum ImportError: LocalizedError {
        case unsupportedVersion(Int)
        var errorDescription: String? {
            switch self {
            case .unsupportedVersion(let v): return "Unsupported knowledge export version \(v)."
            }
        }
    }
}
