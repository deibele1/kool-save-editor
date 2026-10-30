// KSEMac — a KotOR savegame editor for macOS.
// Save-level edits: savegame info, party table, influence, globals, journal, inventory
// and equipment, after KSE (https://gitlab.com/kotorsge-team/kse). GNU GPL v3 or later.
//
// Fixes relative to KSE: inventory items are addressed by position (KSE matched by tag,
// changing or deleting every item sharing it); the time played is mirrored into
// PT_PLAYEDSECONDS and the party size into PT_NUM_MEMBERS; TSL's savenfo PCNAME is
// updated (KSE looked for it in the party table); quests start at their first journal
// entry instead of a fixed state 10; party changes keep the members' leader flags, and the
// party is locked while the player plays as a companion or the story locks it; global
// numbers are the signed bytes (−128…127) the games' scripts use; influence stays within 0…100;
// equipping over an item moves that item to the party inventory (KSE overwrote it, losing it
// and its upgrades).

import Aurora
import Foundation

public struct GlobalVariable: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        case boolean
        case number
        case string
    }

    public var kind: Kind
    public var index: Int
    public var name: String
    public var number: Int
    public var text: String

    public var id: String { "\(kind)-\(index)" }
}

public struct JournalEntry: Sendable, Hashable, Identifiable {
    public var plotID: String
    public var state: Int
    public var date: Int
    public var time: Int
    public var id: String { plotID.lowercased() }
}

public struct InventoryItem: Sendable, Hashable, Identifiable {
    public var index: Int
    public var tag: String
    public var name: GFFLocString?
    public var stackSize: Int
    public var baseItem: Int
    public var modelVariation: Int
    public var id: Int { index }
}

public struct PartyMember: Sendable, Hashable, Identifiable {
    public var index: Int
    public var isAvailable: Bool
    /// False when the story keeps the companion in or out of the party (PT_NPC_SELECT 0).
    public var isSelectable: Bool
    /// The companion the player is playing as (see `SaveGame.controlledCompanion`).
    public var isControlled: Bool
    public var isInParty: Bool
    public var influence: Int?
    public var id: Int { index }
}

extension SaveGame {
    // MARK: Characters

    public func creature(_ id: CharacterID) -> Creature? {
        switch id {
        case .player:
            module.root.list("Mod_PlayerList")?.first.map { Creature($0, encoding: encoding, textLanguage: textLanguage) }
        case .npc(let index):
            npcs[index].map { Creature($0.root, encoding: encoding, textLanguage: textLanguage) }
        }
    }

    public mutating func updateCreature(_ id: CharacterID, _ body: (inout Creature) -> Void) {
        switch id {
        case .player:
            let encoding = encoding, language = textLanguage
            module.root.updateList("Mod_PlayerList") { list in
                guard !list.isEmpty else { return }
                var creature = Creature(list[0], encoding: encoding, textLanguage: language)
                body(&creature)
                list[0] = creature.root
            }
        case .npc(let index):
            guard var document = npcs[index] else { return }
            var creature = Creature(document.root, encoding: encoding, textLanguage: textLanguage)
            body(&creature)
            document.root = creature.root
            npcs[index] = document
        }
    }

    public var companionIndices: [Int] { npcs.keys.sorted() }

    /// Whether the game goes on with this sheet. It doesn't with a transition autosave's player
    /// sheet (the current player is in pifo.ifo) or the sheet of a companion standing in the area.
    public func gameUsesSheet(_ character: CharacterID) -> Bool {
        switch character {
        case .player: !isPCAutosave
        case .npc(let index): !companionsInArea.contains(index)
        }
    }

    /// Whether the player sheet is the player character as the game goes on with it, not a
    /// transition autosave's older copy or a controlled companion's copy.
    public var playerSheetIsCurrent: Bool { !isPCAutosave && controlledCompanion == nil }

    /// The player's name as the party table (PT_PCNAME) or TSL's savenfo (PCNAME) keeps it.
    public var storedPlayerName: String? {
        [party.root.string("PT_PCNAME", encoding: encoding), info.root.string("PCNAME", encoding: encoding)]
            .compactMap { $0 }.first { !$0.isEmpty }
    }

    /// The player's name everywhere the game stores it. When the player sheet is another copy
    /// (`playerSheetIsCurrent` is false), only the sheet is renamed: the game would go on with
    /// the old name, so the player keeps it (PT_PCNAME, PCNAME).
    public mutating func setPlayerName(_ name: String) {
        updateCreature(.player) { $0.setFirstName(name) }
        guard playerSheetIsCurrent else { return }
        if party.root.has("PT_PCNAME") { party.root.setString("PT_PCNAME", name, encoding: encoding) }
        if info.root.has("PCNAME") { info.root.setString("PCNAME", name, encoding: encoding) }
    }

    // MARK: Save information

    public var saveName: String {
        get { info.root.string("SAVEGAMENAME", encoding: encoding) ?? "" }
        set { info.root.setString("SAVEGAMENAME", newValue, encoding: encoding) }
    }

    public var areaName: String { info.root.string("AREANAME", encoding: encoding) ?? "" }

    public var timePlayed: Int {
        get { info.root.integer("TIMEPLAYED") ?? party.root.integer("PT_PLAYEDSECONDS") ?? 0 }
        set {
            info.root.setInteger("TIMEPLAYED", newValue, type: .dword)
            if party.root.has("PT_PLAYEDSECONDS") { party.root.setInteger("PT_PLAYEDSECONDS", newValue, type: .dword) }
        }
    }

    public var cheatUsed: Bool {
        get { (info.root.integer("CHEATUSED") ?? 0) != 0 || (party.root.integer("PT_CHEAT_USED") ?? 0) != 0 }
        set {
            info.root.setInteger("CHEATUSED", newValue ? 1 : 0, type: .byte)
            party.root.setInteger("PT_CHEAT_USED", newValue ? 1 : 0, type: .byte)
        }
    }

    // MARK: Party table

    public var credits: Int {
        get { party.root.integer("PT_GOLD") ?? 0 }
        set { party.root.setInteger("PT_GOLD", newValue, type: .dword) }
    }

    public var partyExperience: Int {
        get { party.root.integer("PT_XP_POOL") ?? 0 }
        set { party.root.setInteger("PT_XP_POOL", newValue, type: .int) }
    }

    public var components: Int? {
        get { party.root.integer("PT_ITEM_COMPONEN") }
        set { if let newValue { party.root.setInteger("PT_ITEM_COMPONEN", newValue, type: .dword) } }
    }

    public var chemicals: Int? {
        get { party.root.integer("PT_ITEM_CHEMICAL") }
        set { if let newValue { party.root.setInteger("PT_ITEM_CHEMICAL", newValue, type: .dword) } }
    }

    public var partyMemberIDs: [Int] {
        party.root.list("PT_MEMBERS")?.compactMap { $0.integer("PT_MEMBER_ID") } ?? []
    }

    public static let maximumPartySize = 2

    /// Replaces the active party (at most two companions), as KSE's Current Party panel did.
    /// Members that stay keep their entries and order, including the leader flag (the
    /// companion the player was steering); new members follow them. PT_CONTROLLED_NP is
    /// never touched: it names who the player is playing as, which a party edit can't change.
    public mutating func setPartyMembers(_ ids: [Int]) {
        var members: [Int] = []
        for id in ids where !members.contains(id) && members.count < Self.maximumPartySize { members.append(id) }
        party.root.updateList("PT_MEMBERS", create: true) { list in
            var kept: [GFFStruct] = []
            for entry in list {
                guard let id = entry.integer("PT_MEMBER_ID"), members.contains(id),
                      !kept.contains(where: { $0.integer("PT_MEMBER_ID") == id }) else { continue }
                kept.append(entry)
            }
            for id in members where !kept.contains(where: { $0.integer("PT_MEMBER_ID") == id }) {
                kept.append(GFFStruct(id: 0, fields: [GFFField(label: "PT_MEMBER_ID", value: .int(Int32(clamping: id))),
                                                      GFFField(label: "PT_IS_LEADER", value: .byte(0))]))
            }
            list = kept
        }
        if party.root.has("PT_NUM_MEMBERS") { party.root.setInteger("PT_NUM_MEMBERS", members.count, type: .byte) }
    }

    public func isCompanionAvailable(_ index: Int) -> Bool {
        guard let entry = party.root.list("PT_AVAIL_NPCS")?[safe: index] else { return false }
        return (entry.integer("PT_NPC_AVAIL") ?? 0) != 0
    }

    /// False while the story keeps a companion in or out of the party: scripts make them
    /// unselectable (PT_NPC_SELECT 0), as with Mandalore on the Ravager.
    public func isCompanionSelectable(_ index: Int) -> Bool {
        guard let entry = party.root.list("PT_AVAIL_NPCS")?[safe: index] else { return false }
        return (entry.integer("PT_NPC_SELECT") ?? 1) != 0
    }

    /// Solo mode (PT_SOLOMODE): the story has the party leader go on alone.
    public var isSoloMode: Bool { (party.root.integer("PT_SOLOMODE") ?? 0) != 0 }

    /// The party is left as the story set it while the player plays as a companion (the player
    /// sheet is their copy, or the party table's PT_CONTROLLED_NP says so) or in solo mode.
    public var canChangeParty: Bool {
        controlledCompanion == nil && (party.root.integer("PT_CONTROLLED_NP") ?? -1) < 0 && !isSoloMode
    }

    /// Whether a companion may be added to or removed from the party.
    public func canToggleCompanion(_ index: Int) -> Bool {
        canChangeParty && isCompanionAvailable(index) && isCompanionSelectable(index)
    }

    /// Every companion slot the party table knows about.
    public var partyMembers: [PartyMember] {
        let slots = max(party.root.list("PT_AVAIL_NPCS")?.count ?? 0, game.standardNPCNames.count)
        let current = Set(partyMemberIDs)
        let controlled = controlledCompanion
        return (0 ..< slots).map {
            PartyMember(index: $0, isAvailable: isCompanionAvailable($0), isSelectable: isCompanionSelectable($0),
                        isControlled: $0 == controlled, isInParty: current.contains($0), influence: influence($0))
        }
    }

    // MARK: Influence (The Sith Lords)

    public var supportsInfluence: Bool { game.hasInfluence || party.root.has("PT_INFLUENCE") }

    /// The influence values the game uses.
    public static let influenceRange = 0 ... 100

    /// A companion's influence, or nil when the party table has no entry for it yet. The game
    /// stores −1 for companions who haven't joined yet.
    public func influence(_ npc: Int) -> Int? {
        guard supportsInfluence, let entry = party.root.list("PT_INFLUENCE")?[safe: npc] else { return nil }
        return entry.integer("PT_NPC_INFLUENCE") ?? entry.fields.first?.value.integer
    }

    /// Sets a companion's influence, clamped to `influenceRange`, creating missing PT_INFLUENCE
    /// entries (at the game's neutral 50) so every companion can be edited, available or not.
    public mutating func setInfluence(_ npc: Int, _ value: Int) {
        guard supportsInfluence, npc >= 0 else { return }
        let value = min(max(value, Self.influenceRange.lowerBound), Self.influenceRange.upperBound)
        party.root.updateList("PT_INFLUENCE", create: true) { list in
            while list.count <= npc {
                let template = list.last.map { entry -> GFFStruct in
                    var copy = entry
                    if let label = copy.has("PT_NPC_INFLUENCE") ? "PT_NPC_INFLUENCE" : copy.fields.first?.label {
                        copy.setInteger(label, 50, type: .int)
                    }
                    return copy
                } ?? GFFStruct(id: 0, fields: [GFFField(label: "PT_NPC_INFLUENCE", value: .int(50))])
                list.append(template)
            }
            let label = list[npc].has("PT_NPC_INFLUENCE") ? "PT_NPC_INFLUENCE" : (list[npc].fields.first?.label ?? "PT_NPC_INFLUENCE")
            list[npc].setInteger(label, value, type: .int)
        }
    }

    // MARK: Global variables

    /// Global numbers are stored as bytes that both games' scripts read as signed.
    public static let globalNumberRange = Int(Int8.min) ... Int(Int8.max)

    public var globalVariables: [GlobalVariable] {
        guard let root = globals?.root else { return [] }
        var result: [GlobalVariable] = []
        let bits = root.void("ValBoolean") ?? []
        for (index, entry) in (root.list("CatBoolean") ?? []).enumerated() {
            let byte = index / 8 < bits.count ? bits[index / 8] : 0
            let value = Int((byte >> (7 - UInt8(index % 8))) & 1)
            result.append(GlobalVariable(kind: .boolean, index: index, name: entry.string("Name", encoding: encoding) ?? "",
                                         number: value, text: ""))
        }
        let numbers = root.void("ValNumber") ?? []
        for (index, entry) in (root.list("CatNumber") ?? []).enumerated() {
            result.append(GlobalVariable(kind: .number, index: index, name: entry.string("Name", encoding: encoding) ?? "",
                                         number: index < numbers.count ? Int(Int8(bitPattern: numbers[index])) : 0, text: ""))
        }
        let strings = root.list("ValString") ?? []
        for (index, entry) in (root.list("CatString") ?? []).enumerated() {
            result.append(GlobalVariable(kind: .string, index: index, name: entry.string("Name", encoding: encoding) ?? "",
                                         number: 0, text: strings[safe: index]?.string("String", encoding: encoding) ?? ""))
        }
        return result
    }

    public func globalBoolean(_ index: Int) -> Bool {
        guard index >= 0, let bits = globals?.root.void("ValBoolean"), index / 8 < bits.count else { return false }
        return (bits[index / 8] >> (7 - UInt8(index % 8))) & 1 == 1
    }

    /// A global number as the scripts see it, in `globalNumberRange` (the byte 0xFF is −1).
    public func globalNumber(_ index: Int) -> Int {
        guard index >= 0, let bytes = globals?.root.void("ValNumber"), index < bytes.count else { return 0 }
        return Int(Int8(bitPattern: bytes[index]))
    }

    public mutating func setGlobalBoolean(_ index: Int, _ value: Bool) {
        guard var root = globals?.root, index >= 0 else { return }
        var bits = root.void("ValBoolean") ?? []
        while bits.count <= index / 8 { bits.append(0) }
        let mask = UInt8(0x80) >> UInt8(index % 8)
        if value { bits[index / 8] |= mask } else { bits[index / 8] &= ~mask }
        root["ValBoolean"] = .void(bits)
        globals?.root = root
    }

    /// Stores a global number, clamped to `globalNumberRange`, as the byte the scripts read.
    public mutating func setGlobalNumber(_ index: Int, _ value: Int) {
        guard var root = globals?.root, index >= 0 else { return }
        var bytes = root.void("ValNumber") ?? []
        while bytes.count <= index { bytes.append(0) }
        bytes[index] = UInt8(bitPattern: Int8(clamping: value))
        root["ValNumber"] = .void(bytes)
        globals?.root = root
    }

    public mutating func setGlobalString(_ index: Int, _ value: String) {
        guard globals != nil, index >= 0 else { return }
        let encoding = encoding
        globals?.root.updateList("ValString", create: true) { list in
            while list.count <= index { list.append(GFFStruct(id: 0, fields: [GFFField(label: "String", value: .exoString([]))])) }
            list[index].setString("String", value, encoding: encoding)
        }
    }

    // MARK: Journal

    public var journalEntries: [JournalEntry] {
        party.root.list("JNL_Entries")?.map {
            JournalEntry(plotID: $0.string("JNL_PlotID", encoding: encoding) ?? "", state: $0.integer("JNL_State") ?? 0,
                         date: $0.integer("JNL_Date") ?? 0, time: $0.integer("JNL_Time") ?? 0)
        } ?? []
    }

    public mutating func setQuestState(_ plotID: String, _ state: Int) {
        let wanted = plotID.lowercased(), encoding = encoding
        party.root.updateList("JNL_Entries") { list in
            for i in list.indices where list[i].string("JNL_PlotID", encoding: encoding)?.lowercased() == wanted {
                list[i].setInteger("JNL_State", state, type: .int)
            }
        }
    }

    public mutating func removeQuests(_ plotIDs: Set<String>) {
        let wanted = Set(plotIDs.map { $0.lowercased() }), encoding = encoding
        party.root.updateList("JNL_Entries") { list in
            list.removeAll { wanted.contains($0.string("JNL_PlotID", encoding: encoding)?.lowercased() ?? "") }
        }
    }

    /// Adds a quest to the journal, dated like the latest entry (as KSE did).
    public mutating func addQuest(_ plotID: String, state: Int) {
        guard !journalEntries.contains(where: { $0.id == plotID.lowercased() }) else { return }
        let last = journalEntries.last
        let encoding = encoding
        party.root.updateList("JNL_Entries", create: true) { list in
            list.append(GFFStruct(id: 0, fields: [
                GFFField(label: "JNL_PlotID", value: .string(plotID, encoding: encoding)),
                GFFField(label: "JNL_State", value: .int(Int32(clamping: state))),
                GFFField(label: "JNL_Date", value: .dword(UInt32(clamping: last?.date ?? 0))),
                GFFField(label: "JNL_Time", value: .dword(UInt32(clamping: last?.time ?? 0))),
            ]))
        }
    }

    // MARK: Inventory

    public var inventoryItems: [InventoryItem] {
        (inventory?.root.list("ItemList") ?? []).enumerated().map { index, item in
            InventoryItem(index: index, tag: item.string("Tag", encoding: encoding) ?? "", name: item.locString("LocalizedName"),
                          stackSize: item.integer("StackSize") ?? 1, baseItem: item.integer("BaseItem") ?? 0,
                          modelVariation: item.integer("ModelVariation") ?? item.integer("TextureVar") ?? 0)
        }
    }

    private mutating func updateItems(_ body: (inout [GFFStruct]) -> Void) {
        if inventory == nil { inventory = GFFDocument(fileType: "INV ") }
        inventory?.root.updateList("ItemList", create: true, body)
    }

    /// Changes a stack; a size of zero removes the item, as in KSE.
    public mutating func setStackSize(_ index: Int, _ size: Int) {
        updateItems { list in
            guard list.indices.contains(index) else { return }
            if size <= 0 { list.remove(at: index) } else { list[index].setInteger("StackSize", size, type: .word) }
        }
    }

    public mutating func removeInventoryItems(_ indices: IndexSet) {
        updateItems { list in
            for index in indices.sorted(by: >) where list.indices.contains(index) { list.remove(at: index) }
        }
    }

    /// Adds `count` of an item blueprint. Stackable items already owned are topped up.
    public mutating func addInventoryItem(_ template: GFFDocument, count: Int, stackLimit: Int = 1) {
        let game = game, encoding = encoding
        let tag = template.root.string("Tag", encoding: encoding)?.lowercased() ?? ""
        updateItems { list in
            if stackLimit > 1, !tag.isEmpty,
               let existing = list.firstIndex(where: { $0.string("Tag", encoding: encoding)?.lowercased() == tag }) {
                let current = list[existing].integer("StackSize") ?? 1
                list[existing].setInteger("StackSize", current + count, type: .word)
            } else {
                list.append(ItemFactory.inventoryItem(from: template, game: game, stackSize: count))
            }
        }
    }

    /// Replaces this save's inventory with another's (KSE's Paste Inventory).
    public mutating func replaceInventory(with items: [GFFStruct]) {
        updateItems { $0 = items }
    }

    // MARK: Equipment

    /// Allocates an object ID the way the engine does, from Module.ifo's Mod_NextObjId0.
    mutating func allocateObjectID() -> UInt32 {
        if let next = module.root.integer("Mod_NextObjId0") {
            module.root.setInteger("Mod_NextObjId0", next + 1, type: .dword)
            return UInt32(clamping: next)
        }
        var highest = 0
        func scan(_ value: GFFStruct) {
            for field in value.fields {
                switch field.value {
                case .dword(let id) where field.label == "ObjectId" && id < 0x7F00_0000: highest = max(highest, Int(id))
                case .structure(let child): scan(child)
                case .list(let items): items.forEach(scan)
                default: break
                }
            }
        }
        scan(module.root)
        return UInt32(highest + 1)
    }

    /// Equips an item blueprint. An item already in the slot goes to the party inventory, as
    /// `unequip` puts it there, and like KSE the new item keeps the slot's object ID; an empty
    /// slot gets a newly allocated one.
    public mutating func equip(_ template: GFFDocument, slot: EquipmentSlot, on character: CharacterID) {
        let replaced = creature(character)?.equippedItem(slot)
        let existingID = replaced?.integer("ObjectId").map { UInt32(clamping: $0) }
        let objectID = existingID ?? allocateObjectID()
        let item = ItemFactory.equippedItem(from: template, game: game, slot: slot, objectID: objectID)
        updateCreature(character) { creature in
            creature.root.updateList("Equip_ItemList", create: true) { list in
                if let index = list.firstIndex(where: { $0.id == slot.rawValue }) { list[index] = item } else { list.append(item) }
            }
            // The hand still holds the slot's object ID, now the new item, so CombatInfo keeps
            // pointing at it; only the name it recorded for the old weapon goes.
            if let existingID { Self.clearCombatInfo(for: Int(existingID), in: &creature.root, keepingReference: true) }
        }
        if let replaced { moveToInventory(replaced) }
    }

    /// Takes off the item in a slot and puts it in the party inventory.
    public mutating func unequip(_ slot: EquipmentSlot, from character: CharacterID) {
        guard let item = creature(character)?.equippedItem(slot) else { return }
        let objectID = item.integer("ObjectId")
        updateCreature(character) { creature in
            creature.root.updateList("Equip_ItemList") { $0.removeAll { $0.id == slot.rawValue } }
            if let objectID { Self.clearCombatInfo(for: objectID, in: &creature.root, keepingReference: false) }
        }
        moveToInventory(item)
    }

    /// Puts an item that left an equipment slot into the party inventory the way the game keeps
    /// inventory items (struct ID 0, no object ID); upgrades and properties stay as they are.
    private mutating func moveToInventory(_ item: GFFStruct) {
        var item = item
        item.id = 0
        item["ObjectId"] = nil
        updateItems { $0.append(item) }
    }

    /// Clears what CombatInfo records about the weapon with this object ID in either hand: its
    /// name, and unless the slot keeps the ID for a replacement, the reference itself.
    private static func clearCombatInfo(for objectID: Int, in creature: inout GFFStruct, keepingReference: Bool) {
        creature.updateStruct("CombatInfo") { info in
            for side in ["Left", "Right"] where info.integer("\(side)Equip") == objectID {
                if !keepingReference { info.setInteger("\(side)Equip", 0x7F00_0000, type: .dword) }
                if info.has("\(side)String") { info.setString("\(side)String", "") }
            }
        }
    }
}
