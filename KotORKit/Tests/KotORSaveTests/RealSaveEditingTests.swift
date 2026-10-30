import Aurora
import Foundation
import KotORSave
import Testing
import TestFixtures

/// Edits copies of the real saves on this Mac (the originals are only read). Skipped when
/// no KotOR saves are installed.
struct RealSaveEditingTests {
    static func installedSaves(_ game: Game? = nil) -> [URL] {
        SaveDiscovery.defaultLocations().filter { game == nil || $0.game == game }.flatMap { SaveDiscovery.saveFolders(in: $0.url) }
    }

    @Test(arguments: Game.allCases)
    func editingACopyOfARealSaveRoundTrips(_ game: Game) throws {
        guard let original = Self.installedSaves(game).first else { return }
        let root = try temporaryDirectory()
        let folder = root.appendingPathComponent("saves/\(original.lastPathComponent)")
        try FileManager.default.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: original, to: folder)
        let store = SaveVersionStore(root: root.appendingPathComponent("Versions"))

        let baseline = try SaveGame.load(from: folder)
        var save = baseline
        let firstItem = try #require(save.inventoryItems.first)
        save.credits += 1000
        save.setPlayerName("Tester")
        save.setStackSize(firstItem.index, firstItem.stackSize + 1)
        save.updateCreature(.player) { $0[.dexterity] += 1 }
        if let companion = save.companionIndices.first { save.updateCreature(.npc(companion)) { $0.experience += 10 } }
        if let flag = save.globalVariables.first(where: { $0.kind == .boolean }) { save.setGlobalBoolean(flag.index, flag.number == 0) }
        #expect(baseline.game == game)
        if game == .kotor2 {
            #expect(baseline.supportsInfluence && baseline.components != nil)
            save.setInfluence(4, 77)
            save.components = (baseline.components ?? 0) + 5
        }

        let result = try SaveWriter.commit(save, baseline: baseline, store: store, summary: "Integration")
        let reloaded = result.reloaded
        if game == .kotor2 {
            #expect(reloaded.influence(4) == 77)
            #expect(reloaded.components == (baseline.components ?? 0) + 5)
            if baseline.playerSheetIsCurrent {
                #expect(reloaded.party.root.string("PT_PCNAME") == "Tester" || !baseline.party.root.has("PT_PCNAME"))
                #expect(reloaded.info.root.string("PCNAME") == "Tester" || !baseline.info.root.has("PCNAME"))
            } else {
                // A transition autosave or a save made while controlling a companion: only the sheet is renamed.
                #expect(reloaded.party.root.string("PT_PCNAME") == baseline.party.root.string("PT_PCNAME"))
                #expect(reloaded.info.root.string("PCNAME") == baseline.info.root.string("PCNAME"))
            }
        }
        #expect(reloaded.credits == baseline.credits + 1000)
        #expect(reloaded.creature(.player)?.firstName?.text(encoding: .windows1252) == "Tester")
        #expect(reloaded.creature(.player)?[.dexterity] == (baseline.creature(.player)?[.dexterity] ?? 0) + 1)
        #expect(reloaded.inventoryItems.first?.stackSize == firstItem.stackSize + 1)
        #expect(reloaded.info == save.info && reloaded.party == save.party && reloaded.globals == save.globals)
        #expect(reloaded.module == save.module && reloaded.npcs == save.npcs && reloaded.inventory == save.inventory)

        let rewritten = try ERFArchive(data: Data(contentsOf: folder.appendingPathComponent(baseline.fileNames.archive)))
        let edited = Set(["inventory", baseline.moduleResRef.lowercased()] + save.companionIndices.prefix(1).map { "availnpc\($0)" })
        for resource in baseline.archive.resources where !edited.contains(resource.resRef.lowercased()) {
            #expect(rewritten.data(for: resource.resRef, type: resource.type) == resource.data, "\(resource.fileName) changed")
        }
        #expect(try Data(contentsOf: folder.appendingPathComponent(baseline.fileNames.screenshot ?? "Screen.tga"))
            == Data(contentsOf: original.appendingPathComponent(baseline.fileNames.screenshot ?? "Screen.tga")))

        try store.restore(try #require(result.version), to: folder)
        for name in baseline.fileNames.all {
            #expect(try Data(contentsOf: folder.appendingPathComponent(name)) == Data(contentsOf: original.appendingPathComponent(name)))
        }
    }

    @Test func everyInstalledSaveLoads() throws {
        for folder in Self.installedSaves() {
            let save = try SaveGame.load(from: folder)
            #expect(save.creature(.player) != nil, "\(folder.lastPathComponent)")
            #expect(!save.saveName.isEmpty || !folder.lastPathComponent.isEmpty)
            _ = try SaveSummary.read(folder: folder, game: save.game)
        }
    }
}
