import XCTest
@testable import Parley

/// Tests for RecordingController.renamePerson (the cross-store fan-out).
/// Uses the static helper form (RecordingController.renamePerson(from:to:vault:voiceprints:))
/// so tests inject temp instances without touching RecordingController.shared.
@MainActor
final class RenamePersonTests: XCTestCase {

    // MARK: - Helpers

    private func makeVP(
        name: String,
        model: String = "wespeaker_v2",
        id: UUID = UUID()
    ) -> Voiceprint {
        let e: [Float] = Array(repeating: 0.1, count: 256)
        return Voiceprint(
            id: id,
            name: name,
            embeddings: [e],
            centroid: e,
            sampleCount: 1,
            createdAt: Date(timeIntervalSinceReferenceDate: 0),
            updatedAt: Date(timeIntervalSinceReferenceDate: 0),
            embeddingModel: model,
            embeddingDim: 256,
            schemaVersion: Voiceprint.currentSchemaVersion,
            audioSample: nil
        )
    }

    /// Set up a temp vault redirected to a temp directory and a temp VoiceprintStore.
    private func withTempContext(
        rolodex: String,
        voiceprintsToEnroll: [Voiceprint] = [],
        body: @MainActor (VaultDirectory, VoiceprintStore) throws -> Void
    ) throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RenamePersonTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let origVaultPath = AppSettings.shared.vaultPath
        let origContactsFileName = AppSettings.shared.contactsFileName
        AppSettings.shared.vaultPath = tmpDir.path
        AppSettings.shared.contactsFileName = "Rolodex.md"
        defer {
            AppSettings.shared.vaultPath = origVaultPath
            AppSettings.shared.contactsFileName = origContactsFileName
        }

        let rolodexURL = tmpDir.appendingPathComponent("Rolodex.md")
        try rolodex.write(to: rolodexURL, atomically: true, encoding: .utf8)

        let vault = VaultDirectory()
        vault.refresh()

        // Use a temp file for the voiceprint store so it does not touch the real one.
        let vpURL = tmpDir.appendingPathComponent("test-voiceprints.json")
        let vpStore = VoiceprintStore(fileURL: vpURL)
        // Manually inject voiceprints by enrolling them.
        for vp in voiceprintsToEnroll {
            _ = vpStore.enroll(name: vp.name, embedding: Array(vp.embeddings.first ?? [0.1]),
                               model: vp.embeddingModel)
        }
        // Restore IDs so tests can find by UUID (enroll creates new UUIDs, so we
        // use name-based lookup in assertions instead).

        try body(vault, vpStore)
    }

    // MARK: - Contact + voiceprint: both renamed

    func testRenamePersonRenamesBothContactAndVoiceprint() throws {
        let rolodex = "## Other\n- **Alice Foo** - Consultant\n"
        let vpAlice = makeVP(name: "Alice Foo")
        try withTempContext(rolodex: rolodex, voiceprintsToEnroll: [vpAlice]) { vault, vpStore in
            RecordingController.renamePerson(from: "Alice Foo", to: "Alice Bar",
                                            vault: vault, voiceprints: vpStore)
            // Rolodex: Alice Bar should exist, Alice Foo should not.
            let contacts = vault.contacts
            XCTAssertNil(contacts.first { $0.name == "Alice Foo" }, "Old contact should be gone")
            XCTAssertNotNil(contacts.first { $0.name == "Alice Bar" }, "New contact should exist")
            // Voiceprints: "Alice Bar" should exist, "Alice Foo" should not.
            let vpNames = vpStore.voiceprints.map { $0.name }
            XCTAssertFalse(vpNames.contains("Alice Foo"), "Old voiceprint name should be gone")
            XCTAssertTrue(vpNames.contains("Alice Bar"), "Voiceprint should be renamed")
        }
    }

    // MARK: - Contact only (no matching voiceprint): contact renamed, voiceprint store unchanged

    func testRenamePersonContactOnly() throws {
        let rolodex = "## Other\n- **Bob Contact** - Manager\n"
        let vpUnrelated = makeVP(name: "Unrelated Person")
        try withTempContext(rolodex: rolodex, voiceprintsToEnroll: [vpUnrelated]) { vault, vpStore in
            let originalVPCount = vpStore.voiceprints.count
            RecordingController.renamePerson(from: "Bob Contact", to: "Bob Renamed",
                                            vault: vault, voiceprints: vpStore)
            // Contact renamed.
            XCTAssertNotNil(vault.contacts.first { $0.name == "Bob Renamed" })
            XCTAssertNil(vault.contacts.first { $0.name == "Bob Contact" })
            // No voiceprint should be affected.
            XCTAssertEqual(vpStore.voiceprints.count, originalVPCount)
            XCTAssertEqual(vpStore.voiceprints.first?.name, "Unrelated Person",
                           "Unrelated voiceprint should be untouched")
        }
    }

    // MARK: - Voiceprint only (no matching contact): voiceprint renamed, vault no-op

    func testRenamePersonVoiceprintOnly() throws {
        // No contact for "Charlie VP" in the rolodex.
        let rolodex = "## Other\n- **Unrelated Contact** - Analyst\n"
        let vpCharlie = makeVP(name: "Charlie VP")
        try withTempContext(rolodex: rolodex, voiceprintsToEnroll: [vpCharlie]) { vault, vpStore in
            let originalContactCount = vault.contacts.count
            RecordingController.renamePerson(from: "Charlie VP", to: "Charlie New",
                                            vault: vault, voiceprints: vpStore)
            // Vault contacts count unchanged (renameContact was a no-op).
            XCTAssertEqual(vault.contacts.count, originalContactCount,
                           "Contact count should not change for a voiceprint-only rename")
            // Voiceprint renamed.
            let vpNames = vpStore.voiceprints.map { $0.name }
            XCTAssertFalse(vpNames.contains("Charlie VP"), "Old voiceprint name should be gone")
            XCTAssertTrue(vpNames.contains("Charlie New"), "Voiceprint should be renamed to new name")
        }
    }

    // MARK: - Multiple voiceprints same name: all renamed

    func testRenamePersonRenamesAllMatchingVoiceprints() throws {
        let rolodex = "## Other\n- **Eve Multi** - Lead\n"
        // Two voiceprints for Eve (dual-engine): both should be renamed.
        let vp1 = makeVP(name: "Eve Multi", model: "wespeaker_v2")
        let vp2 = makeVP(name: "Eve Multi", model: "pyannote_v3")
        try withTempContext(rolodex: rolodex, voiceprintsToEnroll: [vp1, vp2]) { vault, vpStore in
            RecordingController.renamePerson(from: "Eve Multi", to: "Eve Renamed",
                                            vault: vault, voiceprints: vpStore)
            let vpNames = vpStore.voiceprints.map { $0.name }
            XCTAssertEqual(vpNames.filter { $0 == "Eve Multi" }.count, 0,
                           "All voiceprints with old name should be renamed")
            XCTAssertEqual(vpNames.filter { $0 == "Eve Renamed" }.count, 2,
                           "Both voiceprints should carry the new name")
        }
    }

    // MARK: - No-op when names are equal (case-insensitive)

    func testRenamePersonNoOpWhenNamesEqual() throws {
        let rolodex = "## Other\n- **Same Name** - Contractor\n"
        let vp = makeVP(name: "Same Name")
        try withTempContext(rolodex: rolodex, voiceprintsToEnroll: [vp]) { vault, vpStore in
            RecordingController.renamePerson(from: "Same Name", to: "same name",
                                            vault: vault, voiceprints: vpStore)
            // No crash, no side effects: contacts unchanged.
            XCTAssertNotNil(vault.contacts.first { $0.name == "Same Name" })
        }
    }
}
