import AVFoundation
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
        // The level files hold well over a hundred items the BIFs don't, and every entry loads.
        let fromLevels = templates.filter { $0.archive != nil }
        #expect(fromLevels.count > 100 && Set(templates.map(\.id)).count == templates.count)
        #expect(!templates.contains { $0.name.contains("{") })
        for template in fromLevels { #expect(data.itemTemplate(template) != nil, "\(template.id)") }

        let portrait = try #require(data.portraits.values.sorted().first { $0.hasPrefix("po_") })
        let image = await data.assets.image(portrait)
        #expect((image?.width ?? 0) > 0, "portrait \(portrait) did not decode")
        let icons = data.feats.values.compactMap(\.icon).sorted().prefix(10)
        var decoded = 0
        for icon in icons where await data.assets.image(icon) != nil { decoded += 1 }
        #expect(decoded > 0, "no feat icons decoded")
    }

    @Test(arguments: Game.allCases)
    func installedVoiceSetsCanBeHeard(_ game: Game) throws {
        guard let root = SaveDiscovery.gameDataCandidates(for: game).first else { return }
        let data = GameData(game: game, root: root)
        let female = try #require(data.soundsets[83]), male = try #require(data.soundsets[85])
        #expect(female.isPlayer && female.gender == 1 && male.isPlayer && male.gender == 0)
        #expect(!data.soundsets.values.contains { $0.name.contains("*") || $0.name.isEmpty })
        let companions = data.soundsets.values.filter(\.isPartyMember)
        #expect(companions.count >= 9 && companions.allSatisfy(\.hasSounds))
        for voice in companions + [female, male].filter(\.hasSounds) {
            let sample = try #require(data.randomVoiceSample(soundset: voice.id), "no line of \(voice.name) plays")
            let hint = sample.format == .mp3 ? AVFileType.mp3.rawValue : AVFileType.wav.rawValue
            let player = try AVAudioPlayer(data: Data(sample.audio), fileTypeHint: hint)
            #expect(player.duration > 0, "\(voice.name): \(sample.slotName)")
        }
    }

    @Test(arguments: Game.allCases)
    func installedPlayerAndPartyAppearancesShowAFace(_ game: Game) throws {
        guard let root = SaveDiscovery.gameDataCandidates(for: game).first else { return }
        let data = GameData(game: game, root: root)
        let bodies = data.appearances.filter { $0.value.hasPrefix("P_FEM_") || $0.value.hasPrefix("P_MAL_") }
        #expect(bodies.count > 50)
        let party = data.appearances.filter { $0.value.lowercased().hasPrefix("party_npc_") }
        let faceless = bodies.merging(party) { first, _ in first }.filter { data.appearancePortraits[$0.key] == nil }.values.sorted()
        #expect(faceless.isEmpty, "no portrait for \(faceless)")
        #expect(data.appearancePortraits.values.allSatisfy { data.portraits.values.contains($0) })
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
