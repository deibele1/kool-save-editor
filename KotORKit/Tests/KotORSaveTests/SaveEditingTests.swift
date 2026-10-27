import Aurora
import Foundation
import KotORSave
import Testing
import TestFixtures

struct SaveEditingTests {
    func fixture(tsl: Bool = false, signatures: Bool = false) throws -> SaveGame {
        let folder = try temporaryDirectory().appendingPathComponent("000002 - Game1")
        try SaveFixture.write(to: folder, tsl: tsl, signatures: signatures)
        return try SaveGame.load(from: folder)
    }

    @Test func loadsEveryPartOfTheSave() throws {
        let save = try fixture()
        #expect(save.game == .kotor1)
        #expect(save.saveName == "Fixture")
        #expect(save.areaName == "Test Area")
        #expect(save.moduleResRef == SaveFixture.moduleName)
        #expect(save.companionIndices == [0, 2])
        #expect(save.creature(.player)?.firstName?.text(encoding: .windows1252) == "Hero")
        #expect(save.creature(.npc(2))?.firstName?.text(encoding: .windows1252) == "Carth")
        #expect(save.inventoryItems.map(\.stackSize) == [3, 5, 1])
        #expect(save.globalVariables.filter { $0.kind == .boolean }.map(\.number) == [1, 0, 1])
        #expect(save.partyMemberIDs == [2])
        #expect(try fixture(tsl: true).game == .kotor2)
    }

    @Test func playerNameIsWrittenEverywhereTheGameKeepsIt() throws {
        var save = try fixture(tsl: true)
        save.setPlayerName("Meetra")
        let player = try #require(save.creature(.player))
        #expect(player.root.locString("FirstName")?.text(encoding: .windows1252) == "Meetra")
        #expect(player.root.locString("Mod_FirstName")?.text(encoding: .windows1252) == "Meetra")
        #expect(save.party.root.string("PT_PCNAME") == "Meetra")
        #expect(save.info.root.string("PCNAME") == "Meetra")
    }

    @Test func statisticsFollowKSESemantics() throws {
        var save = try fixture()
        save.updateCreature(.player) { creature in
            creature[.strength] = 300
            creature.hitPoints = 80
            creature.forcePoints = 33
            creature.maxForcePoints = 40
            creature.goodEvil = 150
            creature.minimumOneHitPoint = true
            creature.setSkillRank(3, 12)
        }
        let player = try #require(save.creature(.player))
        #expect(player[.strength] == 255)
        #expect(player.hitPoints == 80 && player.currentHitPoints == 80 && player.maxHitPoints == 40)
        #expect(player.forcePoints == 33 && player.currentForce == 33 && player.maxForcePoints == 40)
        #expect(player.goodEvil == 100)
        #expect(player.minimumOneHitPoint)
        #expect(player.skillRanks[3] == 12)
        #expect(player.root.fields.first?.label == "Mod_FirstName", "fields must keep their order")
    }

    @Test func timePlayedAndCheatFlagStayConsistentAcrossFiles() throws {
        var save = try fixture()
        save.timePlayed = 7200
        save.cheatUsed = true
        #expect(save.info.root.integer("TIMEPLAYED") == 7200)
        #expect(save.party.root.integer("PT_PLAYEDSECONDS") == 7200)
        #expect(save.info.root.integer("CHEATUSED") == 1 && save.party.root.integer("PT_CHEAT_USED") == 1)
    }

    @Test func partyChangesUpdateTheMemberCountAndControlledCharacter() throws {
        var save = try fixture()
        save.setPartyMembers([0, 5, 6])
        #expect(save.partyMemberIDs == [0, 5])
        #expect(save.party.root.integer("PT_NUM_MEMBERS") == 2)
        #expect(save.party.root.integer("PT_CONTROLLED_NP") == -1)
        #expect(save.party.root.list("PT_MEMBERS")?.first?.integer("PT_IS_LEADER") == 0)
        #expect(save.partyMembers.filter(\.isAvailable).map(\.index) == [0, 2])
    }

    @Test func influenceIsEditableForEveryCompanion() throws {
        var save = try fixture(tsl: true)
        #expect(save.influence(3) == 43)
        #expect(save.influence(11) == nil)
        save.setInfluence(3, 95)
        save.setInfluence(11, 12)
        #expect(save.influence(3) == 95)
        #expect(save.influence(11) == 12)
        #expect(save.influence(10) == 50, "entries created to reach a companion start neutral")
        #expect(save.party.root.list("PT_INFLUENCE")?.count == 12)
        #expect(save.partyMembers.count == 12)

        var kotor = try fixture()
        kotor.setInfluence(1, 80)
        #expect(!kotor.supportsInfluence && kotor.influence(1) == nil && !kotor.party.root.has("PT_INFLUENCE"))
    }

    @Test func globalsUseMostSignificantBitFirst() throws {
        var save = try fixture()
        save.setGlobalBoolean(1, true)
        save.setGlobalBoolean(0, false)
        save.setGlobalBoolean(10, true)
        #expect(save.globals?.root.void("ValBoolean") == [0b0110_0000, 0b0010_0000])
        save.setGlobalNumber(1, 300)
        save.setGlobalString(0, "tar_m04aa")
        let values = save.globalVariables
        #expect(values.first { $0.kind == .number && $0.index == 1 }?.number == 255)
        #expect(values.first { $0.kind == .string }?.text == "tar_m04aa")
    }

    @Test func journalEditsMatchQuestsByPlotID() throws {
        var save = try fixture()
        save.addQuest("Q_TWO", state: 5)
        save.addQuest("q_two", state: 99)
        save.setQuestState("Q_ONE", 30)
        #expect(save.journalEntries.map(\.plotID) == ["q_one", "Q_TWO"])
        #expect(save.journalEntries.map(\.state) == [30, 5])
        #expect(save.journalEntries.last?.time == 100)
        save.removeQuests(["q_one"])
        #expect(save.journalEntries.map(\.id) == ["q_two"])
    }

    @Test func inventoryEditsAddressItemsByPositionNotTag() throws {
        var save = try fixture()
        save.setStackSize(1, 9)
        #expect(save.inventoryItems.map(\.stackSize) == [3, 9, 1])
        save.setStackSize(0, 0)
        #expect(save.inventoryItems.map(\.stackSize) == [9, 1])

        var template = GFFDocument(fileType: "UTI ")
        template.root = gffStruct(0xFFFF_FFFF, ["BaseItem": .int(1), "Tag": .string("g_i_medeqpmnt01"), "LocalizedName": loc("Medpac"),
                                                "StackSize": .word(1), "Charges": .byte(3), "Comment": .string("ignored")])
        save.addInventoryItem(template, count: 4, stackLimit: 10)
        #expect(save.inventoryItems.map(\.stackSize) == [13, 1], "stackable items top up the existing stack")
        save.addInventoryItem(template, count: 2)
        let added = try #require(save.inventory?.root.list("ItemList")?.last)
        #expect(added.integer("StackSize") == 2)
        #expect(added.integer("MaxCharges") == 3)
        #expect(!added.has("Comment") && !added.has("UpgradeSlot0") && !added.has("BodyVariation"))
        #expect(added.float("XOrientation") == 1)
        save.removeInventoryItems([0, 2])
        #expect(save.inventoryItems.map(\.tag) == ["g_w_lngswrd01"])
    }

    @Test func tslItemsGetUpgradeSlots() throws {
        var save = try fixture(tsl: true)
        var template = GFFDocument(fileType: "UTI ")
        template.root = gffStruct(0xFFFF_FFFF, ["BaseItem": .int(2), "Tag": .string("w"), "UpgradeLevel": .byte(2)])
        save.addInventoryItem(template, count: 1)
        let item = try #require(save.inventory?.root.list("ItemList")?.last)
        #expect(item.integer("UpgradeLevel") == 2 && item.integer("UpgradeSlot5") == -1)
    }

    @Test func featsPowersAndClassesEdit() throws {
        var save = try fixture(tsl: true)
        save.updateCreature(.npc(0)) { creature in
            creature.addFeats([2, 7, 7])
            creature.removeFeats([0])
            creature.addPowers([4, 0], classIndex: 1)
            creature.removePowers([0], classIndex: 1)
            creature.setClassLevel(0, 9)
            creature.addClass(1, isSpellcaster: false)
        }
        var npc = try #require(save.creature(.npc(0)))
        #expect(npc.feats == [2, 7])
        #expect(npc.classes.map(\.classID) == [0, 3, 1])
        #expect(npc.classes[1].powers == [4])
        #expect(npc.classes[0].level == 9 && npc.level == 12)
        let power = try #require(npc.root.list("ClassList")?[1].list("KnownList0")?.first)
        #expect(power.id == 3 && power.integer("SpellFlags") == 1, "new powers copy the layout of existing ones")

        save.updateCreature(.npc(0)) { creature in
            creature.changeClass(1, to: 0, isSpellcaster: false)
            creature.changeClass(0, to: 3, isSpellcaster: true)
            creature.removeClass(2)
        }
        npc = try #require(save.creature(.npc(0)))
        #expect(npc.classes.map(\.classID) == [3, 0])
        #expect(npc.classes[0].powers == [] && npc.classes[1].powers == nil)
        #expect(npc.root.list("ClassList")?[0].list("SpellsPerDayList")?.first?.id == 17767)
        #expect(save.creature(.player)?.feats == [0, 2], "other characters are untouched")
    }

    @Test func equippingReusesObjectIDsAndUnequippingMovesItemsToTheInventory() throws {
        var save = try fixture()
        var rifle = GFFDocument(fileType: "UTI ")
        rifle.root = gffStruct(0xFFFF_FFFF, ["BaseItem": .int(0), "Tag": .string("g_w_blstrrfl002"), "LocalizedName": loc("Better Rifle")])
        save.equip(rifle, slot: .rightWeapon, on: .player)
        save.equip(rifle, slot: .leftWeapon, on: .player)
        let player = try #require(save.creature(.player))
        #expect(player.equippedItem(.rightWeapon)?.integer("ObjectId") == 228)
        #expect(player.equippedItem(.rightWeapon)?.string("Tag") == "g_w_blstrrfl002")
        #expect(player.equippedItem(.leftWeapon)?.integer("ObjectId") == 500)
        #expect(player.equippedItem(.leftWeapon)?.id == EquipmentSlot.leftWeapon.rawValue)
        #expect(save.module.root.integer("Mod_NextObjId0") == 501)

        save.unequip(.rightWeapon, from: .player)
        let after = try #require(save.creature(.player))
        #expect(after.equippedItem(.rightWeapon) == nil)
        #expect(after.root.structure("CombatInfo")?.integer("RightEquip") == 0x7F00_0000)
        #expect(after.root.structure("CombatInfo")?.string("RightString") == "")
        let moved = try #require(save.inventory?.root.list("ItemList")?.last)
        #expect(moved.id == 0 && !moved.has("ObjectId") && moved.string("Tag") == "g_w_blstrrfl002")
    }

    @Test func onlyChangedFilesAreReencoded() throws {
        let baseline = try fixture()
        var save = baseline
        #expect(save.changedFiles(since: baseline).isEmpty)
        save.credits = 9999
        #expect(Set(save.changedFiles(since: baseline).keys) == ["PARTYTABLE.res"])
        save.updateCreature(.npc(2)) { $0[.wisdom] = 18 }
        save.saveName = "Edited"
        #expect(Set(save.changedFiles(since: baseline).keys) == ["PARTYTABLE.res", "SAVEGAME.sav", "savenfo.res"])

        let archive = try ERFArchive(bytes: save.changedFiles(since: baseline)["SAVEGAME.sav"]!)
        for resource in baseline.archive.resources where resource.resRef != "AVAILNPC2" {
            #expect(archive.data(for: resource.resRef, type: resource.type) == resource.data, "\(resource.fileName) must be untouched")
        }
        #expect(archive.resources.map(\.resID) == baseline.archive.resources.map(\.resID))
    }
}
