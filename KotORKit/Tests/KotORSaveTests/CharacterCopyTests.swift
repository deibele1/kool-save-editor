import Aurora
import Foundation
import KotORSave
import Testing
import TestFixtures

/// Saves in which the game goes on with another copy of a character than the sheet the editor
/// shows, and the transition autosave's pifo.ifo in versions.
struct CharacterCopyTests {
    func fixture(_ name: String = "000002 - Game1", tsl: Bool = true, pcAutosave: Bool = false, controlling: Int? = nil,
                 inArea: [Int] = []) throws -> URL {
        let folder = try temporaryDirectory().appendingPathComponent("saves/\(name)")
        try SaveFixture.write(to: folder, tsl: tsl, pcAutosave: pcAutosave, controlling: controlling, inArea: inArea)
        return folder
    }

    func store(for folder: URL) -> SaveVersionStore {
        SaveVersionStore(root: folder.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Versions"))
    }

    /// Rewrites a version's manifest the way earlier builds kept it: without pifo.ifo and
    /// without recording which kinds of file were kept.
    func earlierBuildsVersion(of version: SaveVersion, in store: SaveVersionStore, for folder: URL) throws -> SaveVersion {
        let location = store.location(of: version, for: folder)
        let manifest = location.appendingPathComponent("version.json")
        var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
        json["extensions"] = nil
        for key in ["files", "result"] {
            json[key] = (json[key] as? [[String: Any]])?.filter { $0["name"] as? String != "pifo.ifo" }
        }
        try JSONSerialization.data(withJSONObject: json).write(to: manifest)
        try? FileManager.default.removeItem(at: location.appendingPathComponent("pifo.ifo"))
        return try #require(store.versions(for: folder).first { $0.id == version.id })
    }

    @Test func regularSavesUseTheirSheets() throws {
        for tsl in [false, true] {
            let save = try SaveGame.load(from: try fixture(tsl: tsl))
            #expect(!save.isPCAutosave && save.fileNames.playerIFO == nil)
            #expect(save.controlledCompanion == nil && save.canChangeParty)
            #expect(save.companionsInArea.isEmpty)
            #expect(save.playerSheetIsCurrent && save.gameUsesSheet(.player) && save.gameUsesSheet(.npc(2)))
        }
    }

    @Test func transitionAutosavesKeepThePlayerInPIFO() throws {
        let folder = try fixture("000001 - AUTOSAVE", pcAutosave: true)
        try FileManager.default.moveItem(at: folder.appendingPathComponent("pifo.ifo"), to: folder.appendingPathComponent("PIFO.IFO"))
        var save = try SaveGame.load(from: folder)
        #expect(save.isPCAutosave, "file names are matched ignoring case")
        #expect(save.fileNames.playerIFO == "PIFO.IFO" && save.fileNames.all.contains("PIFO.IFO"))
        #expect(save.creature(.player)?.experience == 12_000, "the sheet is the older copy in Module.ifo")
        #expect(!save.gameUsesSheet(.player) && !save.playerSheetIsCurrent && save.gameUsesSheet(.npc(0)))

        // Renaming the older copy leaves the name the game goes on with alone.
        save.setPlayerName("Captain")
        #expect(save.creature(.player)?.firstName?.text(encoding: .windows1252) == "Captain")
        #expect(save.party.root.string("PT_PCNAME") == "Hero" && save.info.root.string("PCNAME") == "Hero")
        #expect(save.storedPlayerName == "Hero")

        // The game autosaving again is noticed through pifo.ifo as well.
        try Data([1]).write(to: folder.appendingPathComponent("PIFO.IFO"))
        #expect(save.externallyModifiedFiles() == ["PIFO.IFO"])
    }

    @Test func aPIFOCountsOnlyWithThePCAutosaveFlag() throws {
        let leftOver = try fixture(pcAutosave: true)
        var info = try GFFDocument(data: Data(contentsOf: leftOver.appendingPathComponent("savenfo.res")))
        info.root.setInteger("PCAUTOSAVE", 0, type: .byte)
        try Data(info.encoded()).write(to: leftOver.appendingPathComponent("savenfo.res"))
        #expect(try !SaveGame.load(from: leftOver).isPCAutosave)

        let flagOnly = try fixture(pcAutosave: true)
        try FileManager.default.removeItem(at: flagOnly.appendingPathComponent("pifo.ifo"))
        #expect(try !SaveGame.load(from: flagOnly).isPCAutosave)
    }

    @Test func controllingACompanionMakesThePlayerSheetTheirCopy() throws {
        var save = try SaveGame.load(from: try fixture(controlling: 2))
        #expect(save.controlledCompanion == 2)
        #expect(save.partyMembers.filter(\.isControlled).map(\.index) == [2] && !save.canChangeParty)
        #expect(save.creature(.player)?.root.string("Tag") == "carth")
        #expect(save.archive.data(for: "pc", type: .utc) != nil, "the player character is kept in pc.utc")
        #expect(save.gameUsesSheet(.player) && !save.playerSheetIsCurrent, "the game controls this copy")
        #expect(save.storedPlayerName == "Hero", "the player's name, for <FullName>")
        #expect(try SaveGame.load(from: try fixture(tsl: false, controlling: 0)).controlledCompanion == 0)

        // Renaming the sheet renames the companion's copy; the player character keeps its name.
        save.setPlayerName("Captain")
        #expect(save.creature(.player)?.firstName?.text(encoding: .windows1252) == "Captain")
        #expect(save.party.root.string("PT_PCNAME") == "Hero" && save.info.root.string("PCNAME") == "Hero")
    }

    @Test func thePlayerSheetStaysTheCompanionsWhenThePartyTableNoLongerSaysSo() throws {
        // Kool Save Editor 1.1's party edits reset PT_CONTROLLED_NP when the controlled companion
        // left the party; the sheet's tag still says whose copy it is.
        let folder = try fixture(controlling: 2)
        let baseline = try SaveGame.load(from: folder)
        var edited = baseline
        edited.party.root.setInteger("PT_CONTROLLED_NP", -1, type: .int)
        var reloaded = try SaveWriter.commit(edited, baseline: baseline, store: store(for: folder), summary: "Change Party").reloaded
        #expect(reloaded.party.root.integer("PT_CONTROLLED_NP") == -1)
        #expect(reloaded.controlledCompanion == 2 && !reloaded.canChangeParty)
        reloaded.setPlayerName("Captain")
        #expect(reloaded.party.root.string("PT_PCNAME") == "Hero" && reloaded.info.root.string("PCNAME") == "Hero")
    }

    @Test func companionsStandingInTheAreaAreFoundByTag() throws {
        let save = try SaveGame.load(from: try fixture(inArea: [2]))
        #expect(save.companionsInArea == [2], "Bastila and the guard are not Carth")
        #expect(!save.gameUsesSheet(.npc(2)) && save.gameUsesSheet(.npc(0)) && save.gameUsesSheet(.player))
        #expect(try SaveGame.load(from: try fixture(tsl: false, inArea: [0, 2])).companionsInArea == [0, 2])
    }

    @Test func versionsKeepTheAutosavesPIFOAndRestoreIt() throws {
        let folder = try fixture("000001 - AUTOSAVE", pcAutosave: true)
        let store = store(for: folder)
        let pifo = folder.appendingPathComponent("pifo.ifo")
        let original = try Data(contentsOf: pifo)
        let baseline = try SaveGame.load(from: folder)
        var edited = baseline
        edited.credits = 1
        let result = try SaveWriter.commit(edited, baseline: baseline, store: store, summary: "Change Credits")
        let version = try #require(result.version)
        #expect(version.files.map(\.name).contains("pifo.ifo"))
        #expect(!result.writtenFiles.contains("pifo.ifo"))
        #expect(try Data(contentsOf: pifo) == original, "the editor doesn't write pifo.ifo")
        #expect(store.currentState(of: folder)?.changes == "Change Credits")

        // The game autosaves again with a newer player; restoring the original brings back its player.
        try Data([7, 7, 7]).write(to: pifo)
        #expect(store.currentState(of: folder)?.changes == "Change Credits, then changed outside the editor")
        #expect(!store.restoreKeepsCurrentPlayer(version, to: folder))
        try store.restore(version, to: folder)
        #expect(try Data(contentsOf: pifo) == original)
        #expect(try SaveGame.load(from: folder).credits == 100)
    }

    @Test func restoringAVersionWithoutPIFORemovesANewerOne() throws {
        let folder = try fixture()
        let store = store(for: folder)
        let baseline = try SaveGame.load(from: folder)
        var edited = baseline
        edited.credits = 1
        let version = try #require(try SaveWriter.commit(edited, baseline: baseline, store: store, summary: "Change Credits").version)

        // The game writes a transition autosave into the slot; the restore removes its pifo.ifo,
        // and undoing the restore brings it back.
        let pifo = folder.appendingPathComponent("pifo.ifo")
        try Data([7, 7, 7]).write(to: pifo)
        let undo = try store.restore(version, to: folder)
        #expect(!FileManager.default.fileExists(atPath: pifo.path))
        try store.restore(undo, to: folder)
        #expect(try Data(contentsOf: pifo) == Data([7, 7, 7]))
    }

    @Test func versionsFromEarlierBuildsLeaveThePIFOAlone() throws {
        let folder = try fixture("000001 - AUTOSAVE", pcAutosave: true)
        let store = store(for: folder)
        let baseline = try SaveGame.load(from: folder)
        var edited = baseline
        edited.credits = 1
        let saved = try #require(try SaveWriter.commit(edited, baseline: baseline, store: store, summary: "Change Credits").version)

        let legacy = try earlierBuildsVersion(of: saved, in: store, for: folder)
        #expect(legacy.extensions == nil && !legacy.files.map(\.name).contains("pifo.ifo"))
        #expect(store.currentState(of: folder)?.changes == "Change Credits", "pifo.ifo is not an outside change")
        #expect(store.restoreKeepsCurrentPlayer(legacy, to: folder), "the restore dialog says so")
        try store.restore(legacy, to: folder)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("pifo.ifo").path),
                "the game loads the autosave's player from it")
        #expect(try SaveGame.load(from: folder).credits == 100)
    }

    @Test func earlierVersionsOfRegularSavesIgnoreALaterPIFO() throws {
        let folder = try fixture()
        let store = store(for: folder)
        let baseline = try SaveGame.load(from: folder)
        var edited = baseline
        edited.credits = 1
        let saved = try #require(try SaveWriter.commit(edited, baseline: baseline, store: store, summary: "Change Credits").version)
        let legacy = try earlierBuildsVersion(of: saved, in: store, for: folder)

        // The game then writes a transition autosave into the slot. The restored savenfo has no
        // PCAUTOSAVE, so the game doesn't read the pifo.ifo left in place.
        try Data([7, 7, 7]).write(to: folder.appendingPathComponent("pifo.ifo"))
        #expect(!store.restoreKeepsCurrentPlayer(legacy, to: folder))
    }
}
