import Aurora
import Foundation
import KotORSave
import Testing

/// Reads the real game installations on this Mac (read-only). Skipped for games that
/// aren't installed.
struct RealGameDataTests {
    @Test(arguments: Game.allCases)
    func installedGameDataProvidesNamesIconsAndItems(_ game: Game) async throws {
        guard let root = SaveDiscovery.gameDataCandidates(for: game).first else { return }
        let data = GameData(game: game, root: root)
        #expect(data.isAvailable, "\(data.problem ?? "")")
        #expect(data.feats.count > 50 && data.powers.count > 50 && data.classes.count >= 6)
        #expect(data.appearances.count > 100 && data.portraits.count > 20 && data.skills.count == 8)
        #expect(data.baseItems.count > 50 && data.quests.count > 10)
        #expect(data.skillName(0) != "Skill 0" && data.className(0) != "Class 0")

        let templates = await data.assets.itemTemplates()
        #expect(templates.count > 100)
        #expect(templates.filter { !$0.name.isEmpty }.count > templates.count / 2)

        let portrait = try #require(data.portraits.values.sorted().first { $0.hasPrefix("po_") })
        let image = await data.assets.image(portrait)
        #expect((image?.width ?? 0) > 0, "portrait \(portrait) did not decode")
        let icons = data.feats.values.compactMap(\.icon).sorted().prefix(10)
        var decoded = 0
        for icon in icons where await data.assets.image(icon) != nil { decoded += 1 }
        #expect(decoded > 0, "no feat icons decoded")
    }

    @Test func installedSavesUseTheInstalledGameData() throws {
        for location in SaveDiscovery.defaultLocations() {
            guard let root = SaveDiscovery.gameDataCandidates(for: location.game).first else { continue }
            let data = GameData(game: location.game, root: root)
            for folder in SaveDiscovery.saveFolders(in: location.url) {
                let save = try SaveGame.load(from: folder, game: location.game, encoding: data.encoding, textLanguage: data.languageID * 2)
                #expect(save.game == location.game, "\(folder.lastPathComponent) looks like \(save.game)")
                let player = try #require(save.creature(.player))
                #expect(data.text(player.firstName)?.isEmpty == false)
                for item in save.inventoryItems.prefix(20) {
                    #expect(data.text(item.name)?.isEmpty == false, "unnamed item \(item.tag) in \(folder.lastPathComponent)")
                }
                // Cut content (TSL's "hkfactory") can leave entries global.jrl doesn't describe.
                let known = save.journalEntries.filter { data.quests[$0.id] != nil }.count
                #expect(save.journalEntries.isEmpty || known * 2 > save.journalEntries.count)
            }
        }
    }
}
