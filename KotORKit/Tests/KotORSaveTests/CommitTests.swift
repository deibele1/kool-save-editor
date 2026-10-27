import Aurora
import CryptoKit
import Foundation
import KotORSave
import Testing
import TestFixtures

struct CommitTests {
    struct Setup {
        var folder: URL
        var store: SaveVersionStore
        var save: SaveGame
    }

    func setup(signatures: Bool = false, tsl: Bool = false) throws -> Setup {
        let root = try temporaryDirectory()
        let folder = root.appendingPathComponent("saves/000003 - Game2")
        try SaveFixture.write(to: folder, tsl: tsl, signatures: signatures)
        return Setup(folder: folder, store: SaveVersionStore(root: root.appendingPathComponent("Versions")),
                     save: try SaveGame.load(from: folder))
    }

    func contents(_ folder: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) {
            result[name] = try Data(contentsOf: folder.appendingPathComponent(name))
        }
        return result
    }

    @Test func committingWithoutChangesWritesNothing() throws {
        let s = try setup()
        let result = try SaveWriter.commit(s.save, baseline: s.save, store: s.store, summary: "Nothing")
        #expect(result.version == nil && result.writtenFiles.isEmpty)
        #expect(s.store.versions(for: s.folder).isEmpty)
    }

    @Test func committedEditsReloadAndCanBeRolledBack() throws {
        let s = try setup()
        let before = try contents(s.folder)
        var edited = s.save
        edited.credits = 123_456
        edited.updateCreature(.player) { $0[.charisma] = 18 }

        let result = try SaveWriter.commit(edited, baseline: s.save, store: s.store, summary: "Credits and charisma")
        #expect(result.writtenFiles == ["PARTYTABLE.res", "SAVEGAME.sav"])
        #expect(result.reloaded.credits == 123_456)
        #expect(result.reloaded.creature(.player)?[.charisma] == 18)
        let after = try contents(s.folder)
        #expect(after["GLOBALVARS.res"] == before["GLOBALVARS.res"] && after["savenfo.res"] == before["savenfo.res"])
        #expect(!after.keys.contains { $0.hasPrefix(".") }, "no temporary files are left behind")

        let versions = s.store.versions(for: s.folder)
        #expect(versions.count == 1)
        #expect(versions.first?.summary == "Credits and charisma" && versions.first?.reason == .beforeSave)
        #expect(versions.first?.saveName == "Fixture")

        let preRestore = try s.store.restore(try #require(versions.first), to: s.folder)
        #expect(try contents(s.folder) == before)
        #expect(preRestore.reason == .beforeRestore)
        #expect(s.store.versions(for: s.folder).count == 2)
        try s.store.restore(preRestore, to: s.folder)
        #expect(try contents(s.folder) == after)
    }

    @Test func historyStartsWithTheOriginalAndListsEachVersionsChanges() throws {
        let s = try setup()
        #expect(s.store.currentState(of: s.folder) == nil, "no history before the first save")

        var first = s.save
        first.credits = 1
        let saved = try SaveWriter.commit(first, baseline: s.save, store: s.store, summary: "Change Credits").reloaded
        var second = saved
        second.saveName = "Renamed"
        _ = try SaveWriter.commit(second, baseline: saved, store: s.store, summary: "Rename Save")
        #expect(s.store.versions(for: s.folder).map(\.title) == ["Version 2", "Original"])
        #expect(s.store.versions(for: s.folder).map(\.changes) == ["Change Credits", "None"])
        #expect(s.store.versions(for: s.folder).last?.isOriginal == true)
        #expect(s.store.currentState(of: s.folder)?.changes == "Rename Save")

        // The game saves over the slot before the next edit.
        try Data([1, 2, 3]).write(to: s.folder.appendingPathComponent("Screen.tga"))
        #expect(s.store.currentState(of: s.folder)?.changes == "Rename Save, then changed outside the editor")
        var third = try SaveGame.load(from: s.folder)
        third.credits = 2
        _ = try SaveWriter.commit(third, baseline: try SaveGame.load(from: s.folder), store: s.store, summary: "Change Credits")
        #expect(s.store.versions(for: s.folder).first?.title == "Version 3")
        #expect(s.store.versions(for: s.folder).first?.changes == "Rename Save, then changed outside the editor")

        // Restoring the original is itself a version, described by what was restored.
        let original = try #require(s.store.versions(for: s.folder).last)
        try s.store.restore(original, to: s.folder)
        #expect(s.store.versions(for: s.folder).first?.restoringNumber == 1)
        #expect(s.store.currentState(of: s.folder)?.changes == "Restored Original")
        #expect(try SaveGame.load(from: s.folder).credits == 100)

        // Pruning always keeps the original.
        s.store.prune(s.folder, keeping: 1)
        #expect(s.store.versions(for: s.folder).map(\.title) == ["Version 4", "Original"])
        #expect(s.store.versions(for: s.folder).map(\.changes) == ["Change Credits", "None"])
    }

    @Test func playTimeShowsHowLongEachVersionWasPlayed() throws {
        let s = try setup()
        var edited = s.save
        edited.credits = 1
        _ = try SaveWriter.commit(edited, baseline: s.save, store: s.store, summary: "Change Credits")
        #expect(s.store.currentState(of: s.folder)?.timePlayed == 3725)

        // The game is played for an hour and saved over the slot.
        var played = try SaveGame.load(from: s.folder)
        played.timePlayed += 3600
        try Data(played.info.encoded()).write(to: s.folder.appendingPathComponent("savenfo.res"))
        #expect(s.store.currentState(of: s.folder)?.timePlayed == 7325)

        var again = try SaveGame.load(from: s.folder)
        again.credits = 2
        _ = try SaveWriter.commit(again, baseline: try SaveGame.load(from: s.folder), store: s.store, summary: "Change Credits")
        let versions = Array(s.store.versions(for: s.folder).reversed())
        #expect(versions.map(\.timePlayed) == [3725, 7325])
        #expect(versions.map(\.changes) == ["None", "Change Credits, then played"])
        #expect(versions.playTimeDeltas() == [nil, 3600])

        // Restoring the original rewinds the play time.
        try s.store.restore(versions[0], to: s.folder)
        let restored = Array(s.store.versions(for: s.folder).reversed())
        #expect(restored.playTimeDeltas().last == 0)
        #expect(s.store.currentState(of: s.folder)?.timePlayed == 3725)
    }

    @Test func versionsFromEarlierBuildsReadAsATimeline() throws {
        let s = try setup()
        var edited = s.save
        edited.credits = 5
        let saved = try SaveWriter.commit(edited, baseline: s.save, store: s.store, summary: "Change Credits")
        var renamed = saved.reloaded
        renamed.saveName = "Renamed"
        let second = try SaveWriter.commit(renamed, baseline: saved.reloaded, store: s.store, summary: "Rename Save")

        func rewrite(_ version: SaveVersion?, _ change: (inout [String: Any]) -> Void) throws {
            let manifest = s.store.location(of: try #require(version), for: s.folder).appendingPathComponent("version.json")
            var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
            change(&json)
            try JSONSerialization.data(withJSONObject: json).write(to: manifest)
        }
        // The first build wrote no labels; the second wrote "state" labels instead of numbers.
        try rewrite(saved.version) { json in for key in ["number", "changes", "result", "modified", "timePlayed"] { json[key] = nil } }
        try rewrite(second.version) { json in
            for key in ["number", "changes", "result", "timePlayed"] { json[key] = nil }
            json["state"] = "After: Change Credits"
        }

        #expect(s.store.versions(for: s.folder).map(\.title) == ["Version 2", "Original"])
        #expect(s.store.versions(for: s.folder).map(\.changes) == ["Change Credits", "None"])
        #expect(s.store.versions(for: s.folder).map(\.timePlayed) == [3725, 3725], "read from the kept savenfo.res")
        #expect(s.store.currentState(of: s.folder)?.changes == "Rename Save")
    }

    @Test func aRolledBackSaveDoesNotChangeTheHistory() throws {
        let s = try setup()
        var edited = s.save
        edited.credits = 7
        struct Fail: Error {}
        _ = try? SaveWriter.commit(edited, baseline: s.save, store: s.store, summary: "Doomed") { _ in throw Fail() }
        #expect(s.store.versions(for: s.folder).map(\.title) == ["Original"])
        #expect(s.store.currentState(of: s.folder)?.changes == "None", "the save is still the original")
    }

    @Test func aFailedWriteRollsEveryFileBack() throws {
        let s = try setup()
        let before = try contents(s.folder)
        var edited = s.save
        edited.credits = 1
        edited.saveName = "Broken"
        edited.setGlobalNumber(0, 42)

        struct DiskFull: Error {}
        var attempts: [String] = []
        let error = #expect(throws: CommitError.self) {
            try SaveWriter.commit(edited, baseline: s.save, store: s.store, summary: "Doomed") { name in
                attempts.append(name)
                if attempts.count == 2 { throw DiskFull() }
            }
        }
        guard case .writeFailed(let file, _, let rolledBack)? = error else {
            Issue.record("expected a write failure, got \(String(describing: error))")
            return
        }
        #expect(file == "PARTYTABLE.res" && rolledBack)
        #expect(attempts == ["GLOBALVARS.res", "PARTYTABLE.res"])
        #expect(try contents(s.folder) == before)
        #expect(try SaveGame.load(from: s.folder).credits == 100)
    }

    @Test func outsideChangesAreDetectedBeforeWriting() throws {
        let s = try setup()
        var edited = s.save
        edited.credits = 5
        try Data([1, 2, 3]).write(to: s.folder.appendingPathComponent("Screen.tga"))
        #expect(throws: CommitError.self) { try SaveWriter.commit(edited, baseline: s.save, store: s.store, summary: "x") }
        #expect(s.store.versions(for: s.folder).isEmpty)
        let result = try SaveWriter.commit(edited, baseline: s.save, store: s.store, summary: "x", overwriteExternalChanges: true)
        #expect(result.reloaded.credits == 5)
    }

    @Test func oldVersionsArePrunedAndDamagedSnapshotsRefuseToRestore() throws {
        let s = try setup()
        var baseline = s.save
        for credits in 1 ... 4 {
            var edited = baseline
            edited.credits = credits
            baseline = try SaveWriter.commit(edited, baseline: baseline, store: s.store, summary: "\(credits)", retention: 2).reloaded
        }
        let versions = s.store.versions(for: s.folder)
        #expect(versions.map(\.summary) == ["4", "3", "1"], "the newest two plus the original")
        #expect(versions.map(\.title) == ["Version 4", "Version 3", "Original"])
        #expect(versions.map(\.changes) == ["3", "2", "None"])

        let newest = try #require(versions.first)
        let copy = s.store.location(of: newest, for: s.folder).appendingPathComponent("PARTYTABLE.res")
        try Data([0]).write(to: copy)
        #expect(throws: SaveVersionError.self) { try s.store.restore(newest, to: s.folder) }
        #expect(try SaveGame.load(from: s.folder).credits == 4)
    }

    @Test func xboxSignaturesAreRegenerated() throws {
        let s = try setup(signatures: true)
        var edited = s.save
        edited.credits = 777
        let result = try SaveWriter.commit(edited, baseline: s.save, store: s.store, summary: "sig")
        #expect(Set(result.writtenFiles).isSuperset(of: ["SAVE_PARTY.sig", "SAVE_INFO.sig", "SAVE_DATA.sig", "SAVE_HEADERVAR.sig"]))

        let key = SymmetricKey(data: Game.kotor1.signatureKey)
        func signed(_ file: String, _ sig: String) throws {
            let data = try Data(contentsOf: s.folder.appendingPathComponent(file))
            let expected = Data(HMAC<Insecure.SHA1>.authenticationCode(for: data, using: key))
            #expect(try Data(contentsOf: s.folder.appendingPathComponent(sig)) == expected, "\(sig)")
        }
        try signed("PARTYTABLE.res", "SAVE_PARTY.sig")
        try signed("GLOBALVARS.res", "SAVE_VARS.sig")
        try signed("savenfo.res", "SAVE_INFO.sig")
        try signed("Screen.tga", "Screen.sig")

        let archive = [UInt8](try Data(contentsOf: s.folder.appendingPathComponent("SAVEGAME.sav")))
        let reader = BinaryReader(archive)
        let split = Int(try reader.uint32(at: 28)) + 8 * Int(try reader.uint32(at: 16))
        let header = Data(HMAC<Insecure.SHA1>.authenticationCode(for: archive[160 ..< split], using: key))
        let data = Data(HMAC<Insecure.SHA1>.authenticationCode(for: archive[split...], using: key))
        #expect(try Data(contentsOf: s.folder.appendingPathComponent("SAVE_HEADERVAR.sig")) == header)
        #expect(try Data(contentsOf: s.folder.appendingPathComponent("SAVE_DATA.sig")) == data)
    }
}
