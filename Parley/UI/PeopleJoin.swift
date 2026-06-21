import Foundation

/// A presentation-layer aggregate of one person across the two independent stores:
/// the Rolodex contact (VaultDirectory) and their voiceprints (VoiceprintStore).
/// Not persisted; rebuilt on every store change.
struct Person: Identifiable {
    /// Join key, used as id (lowercased for Identifiable uniqueness).
    var id: String { displayName.lowercased() }
    let displayName: String       // canonical name shown in UI
    let contact: Contact?         // nil when voiceprint-only
    let voiceprints: [Voiceprint] // empty when contact-only
    var enrolledEngines: Set<String>  // e.g. {"FluidAudio", "WhisperKit"}
    var anchorID: UUID?           // voiceprints.first?.id; the durable identity anchor
}

/// Maps a VoiceprintStore embeddingModel string to a human-readable engine label.
/// Returns nil for unknown/legacy models.
func engineLabel(for embeddingModel: String) -> String? {
    switch embeddingModel {
    case "wespeaker_v2": return "FluidAudio"
    case "pyannote_v3":  return "WhisperKit"
    default:             return nil
    }
}

/// Pure join of the two stores by name-or-alias (case-insensitive, trimmed).
/// No side effects; no imports of live objects. Safe to call on any actor.
enum PeopleJoin {

    /// Build a sorted [Person] by unioning rolodex contacts and voiceprint names.
    ///
    /// Rules:
    /// - Each contact collects voiceprints whose name equals the contact's canonical
    ///   name OR any of its aliases (case-insensitive, trimmed).
    /// - Voiceprints not matched to any contact form voiceprint-only Persons,
    ///   grouped by trimmed-lowercased name (multiple prints same name => one Person).
    /// - Result sorted by displayName (localized case-insensitive).
    /// - Deterministic: no Date/random.
    static func build(contacts: [Contact], voiceprints: [Voiceprint]) -> [Person] {
        var people: [Person] = []
        var consumedIDs = Set<UUID>()

        // --- Pass 1: contact-anchored Persons ---
        for contact in contacts {
            // Build set of all name keys for this contact (canonical + aliases).
            let keys: Set<String> = Set(
                ([contact.name] + contact.aliases).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            )
            // Match voiceprints by any of those keys.
            let matched = voiceprints.filter { vp in
                keys.contains(vp.name.trimmingCharacters(in: .whitespaces).lowercased())
            }
            let matchedSorted = matched.sorted { $0.createdAt < $1.createdAt }
            for vp in matchedSorted { consumedIDs.insert(vp.id) }

            let engines: Set<String> = Set(matchedSorted.compactMap { engineLabel(for: $0.embeddingModel) })
            let person = Person(
                displayName: contact.name,
                contact: contact,
                voiceprints: matchedSorted,
                enrolledEngines: engines,
                anchorID: matchedSorted.first?.id
            )
            people.append(person)
        }

        // --- Pass 2: voiceprint-only Persons ---
        // Group unconsumed voiceprints by normalized name.
        var groups: [String: [Voiceprint]] = [:]
        for vp in voiceprints where !consumedIDs.contains(vp.id) {
            let key = vp.name.trimmingCharacters(in: .whitespaces).lowercased()
            groups[key, default: []].append(vp)
        }
        for (_, group) in groups {
            let sorted = group.sorted { $0.createdAt < $1.createdAt }
            let displayName = sorted.first?.name ?? ""
            let engines: Set<String> = Set(sorted.compactMap { engineLabel(for: $0.embeddingModel) })
            let person = Person(
                displayName: displayName,
                contact: nil,
                voiceprints: sorted,
                enrolledEngines: engines,
                anchorID: sorted.first?.id
            )
            people.append(person)
        }

        // --- Sort ---
        return people.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }
}
