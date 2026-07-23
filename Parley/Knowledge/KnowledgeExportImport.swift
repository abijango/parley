import Foundation

/// Versioned JSON export/import for terminology + people.
enum KnowledgeExportImport {
    static let currentVersion = 1

    struct Payload: Codable {
        var version: Int
        var exportedAt: Date
        var terminology: [TerminologyEntry]
        var people: [PersonRecord]
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
        let payload = try dec.decode(Payload.self, from: data)
        guard payload.version == currentVersion else {
            throw ImportError.unsupportedVersion(payload.version)
        }
        for entry in payload.terminology {
            terminology.upsert(from: entry.fromText, to: entry.toText, notes: entry.notes,
                               source: entry.source, scope: entry.scope)
        }
        people.replaceAll(contacts: payload.people.map { $0.asContact() })
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
