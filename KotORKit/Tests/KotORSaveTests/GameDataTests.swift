import Aurora
import Foundation
import KotORSave
import Testing
import TestFixtures

struct GameDataTests {
    func install() throws -> GameData {
        let root = try temporaryDirectory().appendingPathComponent("swkotor")
        try GameInstallFixture.write(to: root)
        return GameData(game: .kotor1, root: root)
    }

    @Test func tablesResolveNamesThroughTheTalkTable() throws {
        let data = try install()
        #expect(data.isAvailable && data.problem == nil)
        #expect(data.genderName(1) == "Female")
        #expect(data.genderName(2) == "Both")
        #expect(data.className(0) == "Soldier")
        #expect(data.className(2) == "Scoundrel")
        #expect(data.classes[3]?.isSpellcaster == true && data.classes[0]?.isSpellcaster == false)
        #expect(data.skillName(0) == "Computer Use")
        #expect(data.featName(0) == "Flurry")
        #expect(data.feats[1]?.isCommon == false && data.feats[2]?.isCommon == true)
        #expect(data.powerName(0) == "Force Push" && data.powers[1]?.isCommon == false)
        #expect(data.portraitName(0) == "po_test")
        #expect(data.soundsetName(1) == "Atton" && data.soundsetName(0xFFFF) == "Not set")
        #expect(data.baseItems[0]?.equipableSlots == 0x10 && data.baseItems[0]?.isRanged == true)
        #expect(data.baseItems[2]?.isRanged == false && data.baseItems[1]?.stacking == 10)
        #expect(data.baseItemName(0) == "Rifle" && data.baseItemName(2) == "Long Sword")
        #expect(data.itemIcon(baseItem: 0, modelVariation: 1) == "iw_brifle_001")
    }

    @Test func theLevelCapComesFromTheExperienceTable() throws {
        // The fixture's exptable.2da ends like the games' with an unreachable row (0xFFFFFFFF).
        #expect(try install().maximumLevel == 3)
        #expect(GameData(game: .kotor1, root: nil).maximumLevel == 20)
        #expect(GameData(game: .kotor2, root: nil).maximumLevel == 50)
    }

    @Test func overrideFolderTakesPrecedence() throws {
        let data = try install()
        #expect(data.appearanceName(0) == "PMBOverride")
        #expect(data.appearanceName(2) == "Extra")
        #expect(data.itemTemplate("custom_item")?.root.string("Tag") == "custom_item")
    }

    @Test func voiceSetsAreNamedAndIncludeThePlayers() throws {
        let data = try install()
        #expect(data.soundsetName(0) == "None" && data.soundsetName(2) == "Droid_Astro" && data.soundsetName(40) == "Voice set 40")
        let atton = try #require(data.soundsets[1])
        #expect(atton.hasSounds && atton.isPartyMember && !atton.isPlayer && atton.gender == 0 && atton.isInTable)
        #expect(data.soundsets[0]?.hasSounds == false && data.soundsets[2]?.hasSounds == false)
        #expect(data.soundsets[2]?.isPartyMember == false)
        // Like TSL's, the fixture's soundset.2da has no player rows: they are listed, silent.
        let female = try #require(data.soundsets[83]), male = try #require(data.soundsets[85])
        #expect(female.isPlayer && female.gender == 1 && !female.hasSounds && !female.isInTable && !female.isPartyMember)
        #expect(male.isPlayer && male.gender == 0 && male.name == "Player - Male")
        #expect(GameData(game: .kotor2, root: nil).soundsets.isEmpty)
    }

    @Test func voiceSamplesPlayTheLinesWhoseSoundExists() throws {
        let data = try install()
        var samples: [VoiceSample] = []
        for _ in 0 ..< 6 {
            let sample = try #require(data.randomVoiceSample(soundset: 1, after: samples.last))
            #expect(sample.format == .wave && sample.audio.starts(with: Array("RIFF".utf8)))
            samples.append(sample)
        }
        // Battle cry 2 comes from StreamSounds, the pain grunt from a BIF; selected 1 has no file.
        let slots = samples.map(\.slot)
        #expect(Set(slots) == [1, 12] && zip(slots, slots.dropFirst()).allSatisfy { $0 != $1 })
        let cry = try #require(samples.first { $0.slot == 1 }), grunt = try #require(samples.first { $0.slot == 12 })
        #expect(cry.text == "Time to even the odds." && cry.slotName == "Battle cry")
        #expect(grunt.text == nil && grunt.slotName == "Pain grunt")
        #expect(data.randomVoiceSample(soundset: 2) == nil && data.randomVoiceSample(soundset: 83) == nil)
        #expect(data.randomVoiceSample(soundset: 0xFFFF) == nil)
    }

    @Test func appearancesShowTheFaceOfTheirPortrait() throws {
        let data = try install()
        #expect(data.appearancePortraits[1] == "po_test" && data.appearancePortraits[0] == "po_test")
        #expect(data.appearancePortraits[4] == "po_pfha01" && data.appearancePortraits[5] == "po_pfha01")
        #expect(data.appearancePortraits[3] == "po_pother")
        #expect(data.appearancePortraits[2] == nil)
    }

    @Test func journalCategoriesAreKeyedByLowercaseTag() throws {
        let data = try install()
        #expect(data.quests["q_one"]?.name == "Quest One")
        #expect(data.quests["q_one"]?.entries.map(\.id) == [10, 20])
        #expect(data.quests["q_one"]?.entries.last?.isEnd == true)
        #expect(data.quests["q_two"]?.name == "Inline Quest")
    }

    @Test func templatesAndArtworkLoadLazily() async throws {
        let data = try install()
        let templates = await data.assets.itemTemplates()
        #expect(templates.filter { $0.archive == nil }.map(\.resRef) == ["custom_item", "g_i_medeqpmnt01", "g_w_blstrrfl001"])
        #expect(templates.first { $0.resRef == "g_w_blstrrfl001" }?.name == "Blaster Rifle")
        #expect(templates.first?.isOverride == true)
        let portrait = await data.assets.image("PO_TEST")
        #expect(portrait?.width == 2 && Array(portrait?.pixels.prefix(4) ?? []) == [255, 0, 0, 255])
        #expect(await data.assets.image("missing") == nil)
    }

    @Test func levelFilesAddEveryOtherItemOnce() async throws {
        let data = try install()
        let templates = await data.assets.itemTemplates()
        // Copies that only differ in price (the medpac, the second unique blade) are left out.
        #expect(templates.map(\.id) == ["custom_item", "g_i_medeqpmnt01", "g_rim_item@global.rim", "g_w_blstrrfl001",
                                         "g_w_blstrrfl001@testm01_s.rim", "g_w_unique@testm01_s.rim", "g_w_unique@testm03.mod",
                                         "q_key@testm01_s.rim"])
        let unique = try #require(templates.first { $0.id == "g_w_unique@testm01_s.rim" })
        #expect(unique.name == "Unique Blade" && unique.module == "testm01" && !unique.isPlot && !unique.isOverride)
        #expect(templates.first { $0.id == "g_w_unique@testm03.mod" }?.name == "Unique Blade Mk II")
        #expect(templates.first { $0.resRef == "q_key" }?.isPlot == true)
        #expect(templates.first { $0.resRef == "g_rim_item" }?.module == "global")
        #expect(templates.first { $0.id == "g_i_medeqpmnt01" }?.module == nil)

        for template in templates { #expect(data.itemTemplate(template) != nil, "\(template.id)") }
        #expect(data.itemTemplate(unique)?.root.locString("LocalizedName")?.text(encoding: .windows1252) == "{kds}Unique Blade")
        let variant = try #require(templates.first { $0.id == "g_w_blstrrfl001@testm01_s.rim" })
        #expect(data.itemTemplate(variant)?.root.list("PropertiesList")?.count == 2)
        #expect(data.itemTemplate("g_w_blstrrfl001")?.root.list("PropertiesList")?.count == 1)
    }

    @Test func textHidesTheNotesInCurlyBraces() throws {
        let data = try install()
        #expect(data.text(GFFLocString(substrings: [.init(languageID: 0, bytes: Array("{x01}Handmaiden's Robe".utf8))])) == "Handmaiden's Robe")
        #expect(data.text(GFFLocString(substrings: [.init(languageID: 0, bytes: Array("{only a note}".utf8))])) == nil)
        #expect(GameData.displayed("Components {3}") == "Components" && GameData.displayed("No notes") == "No notes")
    }

    @Test func tokensFillInThePlayersName() {
        let tokens = TextTokens(firstName: "Tindra Nets")
        #expect(tokens.apply("<FullName> Crystal") == "Tindra Nets Crystal")
        #expect(tokens.apply("<FullName>'s condition is stabilized. To fully revive <FirstName>…") == "Tindra Nets's condition is stabilized. To fully revive Tindra Nets…")
        #expect(tokens.apply("Datapad for <fullname>, <PlayerName>") == "Datapad for Tindra Nets, Tindra Nets")
        #expect(tokens.apply(" + dual strike <CUSTOM0>") == " + dual strike <CUSTOM0>")
        #expect(TextTokens(firstName: "Revan", lastName: "Ulic").apply("<FullName> / <LastName>") == "Revan Ulic / Ulic")
        #expect(TextTokens(firstName: "").apply("<FullName> Crystal") == "<FullName> Crystal")
    }

    @Test func aMissingInstallationDegradesToNumbers() {
        let data = GameData(game: .kotor2, root: nil)
        #expect(!data.isAvailable && data.problem != nil)
        #expect(data.featName(12) == "Feat 12")
        #expect(data.skillName(2) == "Stealth")
        #expect(data.text(GFFLocString(stringRef: 5, substrings: [.init(languageID: 0, bytes: Array("Inline".utf8))])) == "Inline")
    }
}

struct DiscoveryTests {
    @Test func findsAppStoreSteamAndCloudSaveFolders() throws {
        let home = try temporaryDirectory()
        let support = "Library/Application Support"
        let paths = [
            "Library/Containers/com.aspyr.kotor/Data/\(support)/Knights of the Old Republic/saves/000001 - Game1",
            "\(support)/Knights of the Old Republic/saves/000000 - QUICKSAVE",
            "\(support)/Star Wars Knights of the Old Republic II/saves",
            "\(support)/Star Wars Knights of the Old Republic II/cloudsaves/76561198000000000/000004 - Game3",
            "Library/Containers/com.aspyr.kotor2.appstore/Data/\(support)/Star Wars Knights of the Old Republic II/saves",
        ]
        for path in paths {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        try SaveFixture.write(to: home.appendingPathComponent(paths[0]))
        try FileManager.default.createDirectory(at: home.appendingPathComponent(paths[0]).deletingLastPathComponent()
            .appendingPathComponent("not a save"), withIntermediateDirectories: true)

        let locations = SaveDiscovery.defaultLocations(home: home)
        #expect(locations.map(\.game) == [.kotor1, .kotor1, .kotor2, .kotor2, .kotor2])
        #expect(locations.map(\.source) == [.steam, .appStore, .steam, .appStore, .steamCloud])
        #expect(locations.last?.sourceTitle == "Steam Cloud (76561198000000000)")

        let appStore = try #require(locations.first { $0.source == .appStore && $0.game == .kotor1 })
        #expect(SaveDiscovery.saveFolders(in: appStore.url).map(\.lastPathComponent) == ["000001 - Game1"])
    }

    @Test func findsSteamCloudSavesInsideTheGameInstallFolder() throws {
        let home = try temporaryDirectory()
        let steam = home.appendingPathComponent("Library/Application Support/Steam")
        let otherLibrary = home.appendingPathComponent("Volumes/Games/SteamLibrary")
        try FileManager.default.createDirectory(at: steam.appendingPathComponent("steamapps"), withIntermediateDirectories: true)
        try """
        "libraryfolders"
        {
        \t"0"\t{ "path"\t\t"\(steam.path)" }
        \t"1"\t{ "path"\t\t"\(otherLibrary.path)" }
        }
        """.write(to: steam.appendingPathComponent("steamapps/libraryfolders.vdf"), atomically: true, encoding: .utf8)

        // TSL with "Use Steam Cloud=1" writes to <install>/cloudsaves/<account>/ next to KOTOR2.app.
        let cloud = steam.appendingPathComponent("steamapps/common/Knights of the Old Republic II/cloudsaves/123456789")
        try SaveFixture.write(to: cloud.appendingPathComponent("000003 - Game2"), tsl: true)
        let otherCloud = otherLibrary.appendingPathComponent("steamapps/common/Knights of the Old Republic II/cloudsaves/12345")
        try FileManager.default.createDirectory(at: otherCloud, withIntermediateDirectories: true)

        let locations = SaveDiscovery.defaultLocations(home: home)
        #expect(locations.map(\.url) == [cloud.standardizedFileURL, otherCloud.standardizedFileURL])
        #expect(locations.allSatisfy { $0.game == .kotor2 && $0.source == .steamCloud })
        #expect(locations.first?.sourceTitle == "Steam Cloud (123456789)")
        #expect(SaveDiscovery.saveFolders(in: cloud).map(\.lastPathComponent) == ["000003 - Game2"])
    }

    @Test func findsGameDataInsideApplicationBundles() throws {
        let home = try temporaryDirectory()
        let steam = home.appendingPathComponent("Library/Application Support/Steam/steamapps/common/Knights of the Old Republic II/KOTOR2.app/Contents/GameData")
        try FileManager.default.createDirectory(at: steam, withIntermediateDirectories: true)
        try Data().write(to: steam.appendingPathComponent("chitin.key"))
        let apps = home.appendingPathComponent("Applications/Knights of the Old Republic.app/Contents/Assets")
        try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
        try Data().write(to: apps.appendingPathComponent("chitin.key"))
        let folders = [home.appendingPathComponent("Applications")]
        #expect(SaveDiscovery.gameDataCandidates(for: .kotor2, home: home, applicationFolders: folders) == [steam.standardizedFileURL])
        #expect(SaveDiscovery.gameDataCandidates(for: .kotor1, home: home, applicationFolders: folders) == [apps.standardizedFileURL])
    }

    @Test func recognizesTheRunningGamesByBundleIdentifier() {
        // Steam and Mac App Store releases, including the App Store container names.
        for id in ["com.aspyr.kotor2.steam", "com.aspyr.kotor2.appstore", "com.aspyr.kotor2", "COM.Aspyr.KOTOR2.Steam"] {
            #expect(Game(bundleIdentifier: id) == .kotor2, "\(id)")
        }
        for id in ["com.aspyr.kotor", "com.aspyr.kotor.appstore", "com.aspyr.kotor.steam", "com.Aspyr.KotOR"] {
            #expect(Game(bundleIdentifier: id) == .kotor1, "\(id)")
        }
        for id in ["", "com.aspyr", "com.aspyr.kotorremake", "com.aspyr.civ6", "com.valvesoftware.steam", "Sempervia.KSEMac"] {
            #expect(Game(bundleIdentifier: id) == nil, "\(id)")
        }
    }
}
