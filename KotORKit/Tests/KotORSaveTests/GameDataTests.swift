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
        #expect(data.soundsetName(1) == "Player Female" && data.soundsetName(0xFFFF) == "None")
        #expect(data.baseItems[0]?.equipableSlots == 0x10 && data.baseItems[0]?.isRanged == true)
        #expect(data.baseItems[2]?.isRanged == false && data.baseItems[1]?.stacking == 10)
        #expect(data.itemIcon(baseItem: 0, modelVariation: 1) == "iw_brifle_001")
    }

    @Test func overrideFolderTakesPrecedence() throws {
        let data = try install()
        #expect(data.appearanceName(0) == "PMBOverride")
        #expect(data.appearanceName(2) == "Extra")
        #expect(data.itemTemplate("custom_item")?.root.string("Tag") == "custom_item")
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
        #expect(templates.map(\.resRef) == ["custom_item", "g_i_medeqpmnt01", "g_w_blstrrfl001"])
        #expect(templates.first { $0.resRef == "g_w_blstrrfl001" }?.name == "Blaster Rifle")
        #expect(templates.first?.isOverride == true)
        let portrait = await data.assets.image("PO_TEST")
        #expect(portrait?.width == 2 && Array(portrait?.pixels.prefix(4) ?? []) == [255, 0, 0, 255])
        #expect(await data.assets.image("missing") == nil)
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
}
