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
        #expect(player[.strength] == Creature.maximumAbilityScore)
        #expect(player.hitPoints == 80 && player.currentHitPoints == 80 && player.maxHitPoints == 40)
        #expect(player.forcePoints == 33 && player.currentForce == 33 && player.maxForcePoints == 40)
        #expect(player.goodEvil == 100)
        #expect(player.minimumOneHitPoint)
        #expect(player.skillRanks[3] == 12)
        #expect(player.root.fields.first?.label == "Mod_FirstName", "fields must keep their order")
    }

    @Test func attributesAndSkillRanksStayWhereTheGamesReadThemCorrectly() throws {
        var save = try fixture(tsl: true)
        save.updateCreature(.player) { creature in
            creature[.dexterity] = 255
            creature[.constitution] = -4
            creature[.wisdom] = 100
            creature.setSkillRank(0, 255)
            creature.setSkillRank(1, 128)
            creature.setSkillRank(2, 127)
            creature.setSkillRank(4, -1)
        }
        let player = try #require(save.creature(.player))
        // The games add bonuses to attributes in 8 bits (255 with a +2 belt is 1) and read ranks
        // as signed bytes (255 is −1).
        #expect(player[.dexterity] == 100 && player[.constitution] == 0 && player[.wisdom] == 100)
        #expect(player.skillRanks.prefix(5) == [127, 127, 127, 3, 0])
        #expect(player.root.list("SkillList")?[0]["Rank"] == .byte(127), "ranks stay bytes")
        #expect(Creature.maximumAbilityScore + Int(Int8.max) <= 255, "even the largest effect bonus can't wrap")

        // Values already in a save are read as they are, so the editor can warn about them.
        save.updateCreature(.npc(0)) { $0.root.updateList("SkillList") { $0[6]["Rank"] = .byte(200) } }
        #expect(save.creature(.npc(0))?.skillRanks[6] == 200)
    }

    @Test func timePlayedAndCheatFlagStayConsistentAcrossFiles() throws {
        var save = try fixture()
        save.timePlayed = 7200
        save.cheatUsed = true
        #expect(save.info.root.integer("TIMEPLAYED") == 7200)
        #expect(save.party.root.integer("PT_PLAYEDSECONDS") == 7200)
        #expect(save.info.root.integer("CHEATUSED") == 1 && save.party.root.integer("PT_CHEAT_USED") == 1)
    }

    @Test func partyChangesUpdateTheMemberCountAndKeepTheLeader() throws {
        var save = try fixture()
        save.setPartyMembers([0, 5, 6])
        #expect(save.partyMemberIDs == [0, 5])
        #expect(save.party.root.integer("PT_NUM_MEMBERS") == 2)
        #expect(save.party.root.list("PT_MEMBERS")?.first?.integer("PT_IS_LEADER") == 0)
        #expect(save.partyMembers.filter(\.isAvailable).map(\.index) == [0, 2])

        // The player steers Carth in the field: he stays the leader, first, while others change.
        save.party.root["PT_MEMBERS"] = .list([gffStruct(0, ["PT_MEMBER_ID": .int(2), "PT_IS_LEADER": .byte(1)]),
                                               gffStruct(0, ["PT_MEMBER_ID": .int(0), "PT_IS_LEADER": .byte(0)])])
        func members() -> [[Int]] {
            save.party.root.list("PT_MEMBERS")?.map { [$0.integer("PT_MEMBER_ID") ?? -1, $0.integer("PT_IS_LEADER") ?? -1] } ?? []
        }
        save.setPartyMembers([2])
        #expect(members() == [[2, 1]] && save.party.root.integer("PT_NUM_MEMBERS") == 1)
        save.setPartyMembers([0, 2, 0])
        #expect(members() == [[2, 1], [0, 0]] && save.party.root.integer("PT_NUM_MEMBERS") == 2)
        #expect(save.party.root.integer("PT_CONTROLLED_NP") == -1)
    }

    @Test func thePartyIsLockedWhereTheStoryLocksIt() throws {
        var save = try fixture(tsl: true)
        #expect(save.controlledCompanion == nil && !save.isSoloMode && save.canChangeParty)
        #expect(save.canToggleCompanion(0) && save.canToggleCompanion(2) && !save.canToggleCompanion(1), "1 is not available")

        // The story keeps a companion in the party, like Mandalore on the Ravager.
        save.party.root.updateList("PT_AVAIL_NPCS") { $0[2].setInteger("PT_NPC_SELECT", 0, type: .byte) }
        #expect(!save.canToggleCompanion(2) && save.canToggleCompanion(0))
        #expect(save.partyMembers[2].isSelectable == false && save.partyMembers[0].isSelectable)

        // The player plays as Atton (SwitchPlayerCharacter): the whole party is locked, even when
        // only the party table says so, and a party change made anyway leaves PT_CONTROLLED_NP
        // alone. CharacterCopyTests covers saves whose player sheet is the companion's copy.
        save.party.root.setInteger("PT_CONTROLLED_NP", 0, type: .int)
        save.party.root["PT_MEMBERS"] = .list([])
        #expect(!save.canChangeParty)
        #expect(!save.canToggleCompanion(0) && !save.canToggleCompanion(2))
        save.setPartyMembers([2])
        #expect(save.party.root.integer("PT_CONTROLLED_NP") == 0 && save.partyMemberIDs == [2])

        save.party.root.setInteger("PT_CONTROLLED_NP", -1, type: .int)
        save.party.root.setInteger("PT_SOLOMODE", 1, type: .byte)
        #expect(save.isSoloMode && !save.canChangeParty && !save.canToggleCompanion(0))
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

        // The game keeps −1 until a companion joins; edits stay within 0…100.
        save.party.root.updateList("PT_INFLUENCE") { $0[5].setInteger("PT_NPC_INFLUENCE", -1) }
        #expect(save.influence(5) == -1)
        save.setInfluence(5, -40)
        save.setInfluence(4, 250)
        #expect(save.influence(5) == 0 && save.influence(4) == 100)

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
        #expect(values.first { $0.kind == .number && $0.index == 1 }?.number == 127)
        #expect(values.first { $0.kind == .string }?.text == "tar_m04aa")
    }

    @Test func globalNumbersAreTheSignedBytesTheScriptsRead() throws {
        var save = try fixture()
        // The fixture stores 5 and 200; scripts read the byte 200 (0xC8) as −56.
        #expect(save.globalVariables.filter { $0.kind == .number }.map(\.number) == [5, -56])
        #expect(save.globalNumber(1) == -56 && save.globalNumber(7) == 0)

        // Writing back what was read keeps every byte.
        let original = save.globals
        for variable in save.globalVariables where variable.kind == .number { save.setGlobalNumber(variable.index, variable.number) }
        #expect(save.globals == original)

        save.setGlobalNumber(0, -1)
        save.setGlobalNumber(1, -4)
        #expect(save.globals?.root.void("ValNumber") == [0xFF, 0xFC])
        #expect(save.globalNumber(0) == -1 && save.globalNumber(1) == -4)
        save.setGlobalNumber(0, 128)
        save.setGlobalNumber(1, -500)
        #expect(save.globals?.root.void("ValNumber") == [0x7F, 0x80])
        #expect(save.globalNumber(0) == 127 && save.globalNumber(1) == -128)
        #expect(SaveGame.globalNumberRange == -128 ... 127)

        // Bytes past the end are filled with zeros, as before.
        save.setGlobalNumber(3, -2)
        #expect(save.globals?.root.void("ValNumber") == [0x7F, 0x80, 0, 0xFE])
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
            creature.setClassLevel(0, 9)
            creature.removeClass(1)
            creature.addClass(1, isSpellcaster: false)
        }
        var npc = try #require(save.creature(.npc(0)))
        #expect(npc.feats == [2, 7])
        #expect(npc.classes.map(\.classID) == [0, 1])
        #expect(npc.classes[1].powers == nil && npc.classes[1].level == 1)
        #expect(npc.classes[0].level == 9 && npc.level == 10)

        save.updateCreature(.npc(2)) { creature in
            creature.addPowers([4, 0], classIndex: 1)
            creature.removePowers([0], classIndex: 1)
        }
        let carth = try #require(save.creature(.npc(2)))
        #expect(carth.classes[1].powers == [4])
        let power = try #require(carth.root.list("ClassList")?[1].list("KnownList0")?.first)
        #expect(power.id == 3 && power.integer("SpellFlags") == 1, "new powers copy the layout of existing ones")

        save.updateCreature(.npc(2)) { creature in
            creature.changeClass(1, to: 1, isSpellcaster: false)
            creature.changeClass(0, to: 3, isSpellcaster: true)
        }
        npc = try #require(save.creature(.npc(2)))
        #expect(npc.classes.map(\.classID) == [3, 1])
        #expect(npc.classes[0].powers == [] && npc.classes[1].powers == nil)
        #expect(npc.root.list("ClassList")?[0].list("SpellsPerDayList")?.first?.id == 17767)
        #expect(save.creature(.player)?.feats == [0, 2], "other characters are untouched")
    }

    @Test func aClassCanNeitherRepeatNorBeAThird() throws {
        var save = try fixture()
        save.updateCreature(.player) { creature in
            creature.addClass(2, isSpellcaster: false)
            creature.changeClass(1, to: 0, isSpellcaster: false)
            creature.changeClass(0, to: 3, isSpellcaster: true)
            creature.changeClass(5, to: 2, isSpellcaster: false)
        }
        var player = try #require(save.creature(.player))
        #expect(player.classes.map(\.classID) == [0, 3], "a third class or a class twice makes the games ignore or refuse the creature")
        #expect(player.classes[1].powers == [0], "a refused change keeps the powers")
        #expect(!player.canAddClass(2) && !player.canChangeClass(1, to: 0) && !player.canChangeClass(2, to: 1))
        #expect(player.canChangeClass(1, to: 2) && player.canChangeClass(1, to: 3))

        save.updateCreature(.player) { creature in
            creature.removeClass(1)
            creature.addClass(0, isSpellcaster: false)
        }
        player = try #require(save.creature(.player))
        #expect(player.classes.map(\.classID) == [0])
        #expect(player.canAddClass(3) && !player.canAddClass(0) && player.canChangeClass(0, to: 2))
        save.updateCreature(.player) { $0.addClass(3, isSpellcaster: true) }
        #expect(save.creature(.player)?.classes.map(\.classID) == [0, 3])
        #expect(save.creature(.player)?.classes.last?.powers == [])
    }

    @Test func classLevelsStopAtTheLevelCap() throws {
        let player = try #require(try fixture().creature(.player))
        // Soldier 5 / Jedi 2 under KotOR's cap of 20.
        #expect(player.levelLimit(forClass: 0, cap: 20) == 18 && player.levelLimit(forClass: 1, cap: 20) == 15)
        #expect(player.levelLimit(forClass: 0, cap: 50) == 48)
        #expect(player.levelLimit(forClass: 0, cap: 6) == 5, "a level past the cap is kept, not lowered")
        #expect(player.levelLimit(forClass: 1, cap: 4) == 2 && player.levelLimit(forClass: 9, cap: 3) == 1)
        #expect(Game.kotor1.maximumLevel == 20 && Game.kotor2.maximumLevel == 50)
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

    @Test(arguments: [false, true])
    func replacingEquipmentMovesTheOldItemToTheInventory(tsl: Bool) throws {
        var original = try fixture(tsl: tsl)
        // An upgraded weapon in the player's right hand (object 228, named in CombatInfo).
        original.updateCreature(.player) { creature in
            creature.root.updateList("Equip_ItemList") { list in
                list[0]["Upgrades"] = .dword(5)
                list[0]["PropertiesList"] = .list([gffStruct(0, ["PropertyName": .word(11), "Subtype": .word(3)])])
                if tsl {
                    list[0]["UpgradeLevel"] = .byte(2)
                    for slot in 0 ..< 6 { list[0]["UpgradeSlot\(slot)"] = .int(slot < 2 ? Int32(40 + slot) : -1) }
                }
            }
        }
        var rifle = GFFDocument(fileType: "UTI ")
        rifle.root = gffStruct(0xFFFF_FFFF, ["BaseItem": .int(0), "Tag": .string("g_w_blstrrfl002"), "LocalizedName": loc("Better Rifle")])

        var save = original
        save.equip(rifle, slot: .rightWeapon, on: .player)
        let player = try #require(save.creature(.player))
        let equipped = try #require(player.equippedItem(.rightWeapon))
        #expect(equipped.string("Tag") == "g_w_blstrrfl002" && equipped.integer("ObjectId") == 228, "the new item keeps the slot's object ID")
        #expect(player.root.list("Equip_ItemList")?.count == 1)
        #expect(save.module.root.integer("Mod_NextObjId0") == 500, "no object ID is allocated")

        // The old item reaches the inventory exactly as Unequip puts it there, upgrades included.
        var unequipped = original
        unequipped.unequip(.rightWeapon, from: .player)
        let items = try #require(save.inventory?.root.list("ItemList"))
        #expect(items.count == original.inventoryItems.count + 1)
        let moved = try #require(items.last)
        #expect(moved == unequipped.inventory?.root.list("ItemList")?.last)
        #expect(moved.id == 0 && !moved.has("ObjectId") && moved.string("Tag") == "g_w_blstrrfl001")
        #expect(moved.integer("Upgrades") == 5 && moved.list("PropertiesList")?.first?.integer("Subtype") == 3)
        if tsl { #expect(moved.integer("UpgradeLevel") == 2 && moved.integer("UpgradeSlot1") == 41 && moved.integer("UpgradeSlot2") == -1) }

        // The right hand still holds object 228, now the new rifle; the old rifle's name goes.
        let combat = try #require(player.root.structure("CombatInfo"))
        #expect(combat.integer("RightEquip") == 228 && combat.string("RightString") == "")
        #expect(combat.integer("LeftEquip") == 0x7F00_0000)

        // Filling an empty slot replaces nothing.
        save.equip(rifle, slot: .leftWeapon, on: .player)
        #expect(save.inventory?.root.list("ItemList")?.count == items.count)
    }

    @Test func replacingACompanionsEquipmentFillsThePartyInventory() throws {
        var save = try fixture()
        var sword = GFFDocument(fileType: "UTI ")
        sword.root = gffStruct(0xFFFF_FFFF, ["BaseItem": .int(2), "Tag": .string("g_w_vbroswrd01"), "LocalizedName": loc("Vibrosword")])
        save.equip(sword, slot: .rightWeapon, on: .npc(2))
        let carth = try #require(save.creature(.npc(2)))
        #expect(carth.equippedItem(.rightWeapon)?.string("Tag") == "g_w_vbroswrd01")
        #expect(carth.equippedItem(.rightWeapon)?.integer("ObjectId") == 228)
        #expect(save.inventoryItems.map(\.tag) == ["g_i_medeqpmnt01", "g_i_medeqpmnt01", "g_w_lngswrd01", "g_w_blstrrfl001"])
        #expect(save.creature(.player)?.equippedItem(.rightWeapon)?.string("Tag") == "g_w_blstrrfl001", "the player is untouched")
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

    @Test func allFilesAreTheSaveAsReadPlusTheEdits() throws {
        let baseline = try fixture()
        var expected: [String: [UInt8]] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: baseline.folder.path) {
            expected[name] = [UInt8](try Data(contentsOf: baseline.folder.appendingPathComponent(name)))
        }
        #expect(baseline.otherFiles.keys.sorted() == ["Screen.tga"])
        #expect(baseline.allFiles(since: baseline) == expected, "unchanged files re-encode to the bytes read")

        var save = baseline
        save.credits = 9999
        expected["PARTYTABLE.res"] = save.party.encoded()
        #expect(save.allFiles(since: baseline) == expected)
    }
}
