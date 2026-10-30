// KSEMac — a KotOR savegame editor for macOS.
// Typed access to a creature struct (the player in Module.ifo, or a companion's
// AVAILNPC<n>.utc), after KSE's Spawn*Widgets handlers
// (https://gitlab.com/kotorsge-team/kse). GNU GPL v3 or later.
//
// Fixes relative to KSE: editing Force Points no longer writes into the struct's first
// field; changing a Jedi class to a non-Jedi class removes the power lists (KSE's
// condition could never be true); classes, feats and powers are addressed by position
// or ID instead of display text; renaming the player also updates Mod_FirstName;
// attributes stop at 100 and skill ranks at 127, values the games read without wrapping
// around; a class can't be added twice or as a third class.

import Aurora
import Foundation

public enum CharacterID: Hashable, Sendable {
    case player
    case npc(Int)
}

public enum Ability: String, CaseIterable, Sendable, Identifiable {
    case strength = "Str"
    case dexterity = "Dex"
    case constitution = "Con"
    case intelligence = "Int"
    case wisdom = "Wis"
    case charisma = "Cha"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .strength: "Strength"
        case .dexterity: "Dexterity"
        case .constitution: "Constitution"
        case .intelligence: "Intelligence"
        case .wisdom: "Wisdom"
        case .charisma: "Charisma"
        }
    }

    public var abbreviation: String { rawValue.uppercased() }
}

public enum EquipmentSlot: UInt32, CaseIterable, Sendable, Identifiable {
    case head = 0x1
    case implant = 0x200
    case armor = 0x2
    case gloves = 0x8
    case rightArm = 0x100
    case leftArm = 0x80
    case belt = 0x400
    case rightWeapon = 0x10
    case leftWeapon = 0x20
    case rightWeapon2 = 0x40000
    case leftWeapon2 = 0x80000

    public var id: UInt32 { rawValue }

    public var title: String {
        switch self {
        case .head: "Head"
        case .implant: "Implant"
        case .armor: "Armor"
        case .gloves: "Gloves"
        case .rightArm: "Right Arm"
        case .leftArm: "Left Arm"
        case .belt: "Belt"
        case .rightWeapon: "Right Weapon"
        case .leftWeapon: "Left Weapon"
        case .rightWeapon2: "Right Weapon 2"
        case .leftWeapon2: "Left Weapon 2"
        }
    }

    public var isWeapon: Bool {
        [.rightWeapon, .leftWeapon, .rightWeapon2, .leftWeapon2].contains(self)
    }

    /// The bit baseitems.2da's `equipableslots` uses; the second weapon set shares the first's.
    public var equipBit: Int {
        switch self {
        case .rightWeapon2: Int(EquipmentSlot.rightWeapon.rawValue)
        case .leftWeapon2: Int(EquipmentSlot.leftWeapon.rawValue)
        default: Int(rawValue)
        }
    }

    public static func slots(for game: Game) -> [EquipmentSlot] {
        game.hasSecondWeaponSet ? allCases : allCases.filter { $0 != .rightWeapon2 && $0 != .leftWeapon2 }
    }
}

public struct CreatureClass: Sendable, Hashable, Identifiable {
    public var index: Int
    public var classID: Int
    public var level: Int
    /// Known Force powers, or nil when the class has no power list.
    public var powers: [Int]?

    public var id: Int { index }
}

public struct Creature: Sendable, Equatable {
    public var root: GFFStruct
    public var encoding: TextEncoding
    public var textLanguage: UInt32

    public init(_ root: GFFStruct, encoding: TextEncoding, textLanguage: UInt32) {
        self.root = root
        self.encoding = encoding
        self.textLanguage = textLanguage
    }

    // MARK: Identity

    public var firstName: GFFLocString? { root.locString("FirstName") }
    public var lastName: GFFLocString? { root.locString("LastName") }

    public mutating func setFirstName(_ name: String) {
        for label in ["FirstName", "Mod_FirstName"] {
            guard root.has(label) || label == "FirstName" else { continue }
            var loc = root.locString(label) ?? GFFLocString()
            loc.setText(name, encoding: encoding, languageID: textLanguage)
            root[label] = .locString(loc)
        }
    }

    public var gender: Int {
        get { root.integer("Gender") ?? 0 }
        set { root.setInteger("Gender", newValue, type: .byte) }
    }

    public var appearance: Int {
        get { root.integer("Appearance_Type") ?? 0 }
        set { root.setInteger("Appearance_Type", newValue, type: .word) }
    }

    public var portrait: Int {
        get { root.integer("PortraitId") ?? 0 }
        set { root.setInteger("PortraitId", newValue, type: .word) }
    }

    public var soundset: Int {
        get { root.integer("SoundSetFile") ?? 0xFFFF }
        set { root.setInteger("SoundSetFile", newValue, type: .word) }
    }

    // MARK: Statistics

    /// The highest attribute score that can be set. The games add the item and Force bonuses
    /// (one signed byte, so at most +127) and the racial adjustment to the stored score in
    /// 8 bits: a total above 255 wraps around (255 with a +2 belt is read as 1). 100 + 127
    /// still leaves room for the racial adjustments, and 100 is already a +45 modifier.
    public static let maximumAbilityScore = 100

    public subscript(ability: Ability) -> Int {
        get { root.integer(ability.rawValue) ?? 0 }
        set { root.setInteger(ability.rawValue, min(Self.maximumAbilityScore, max(0, newValue)), type: .byte) }
    }

    /// Base hit points; as in KSE, setting them also refills the current hit points.
    public var hitPoints: Int {
        get { root.integer("HitPoints") ?? 0 }
        set {
            root.setInteger("HitPoints", newValue, type: .short)
            root.setInteger("CurrentHitPoints", newValue, type: .short)
        }
    }

    public var currentHitPoints: Int {
        get { root.integer("CurrentHitPoints") ?? 0 }
        set { root.setInteger("CurrentHitPoints", newValue, type: .short) }
    }

    public var maxHitPoints: Int {
        get { root.integer("MaxHitPoints") ?? 0 }
        set { root.setInteger("MaxHitPoints", newValue, type: .short) }
    }

    /// Base Force points; as in KSE, setting them also refills the current Force points.
    public var forcePoints: Int {
        get { root.integer("ForcePoints") ?? 0 }
        set {
            root.setInteger("ForcePoints", newValue, type: .short)
            root.setInteger("CurrentForce", newValue, type: .short)
        }
    }

    public var currentForce: Int {
        get { root.integer("CurrentForce") ?? 0 }
        set { root.setInteger("CurrentForce", newValue, type: .short) }
    }

    public var maxForcePoints: Int {
        get { root.integer("MaxForcePoints") ?? 0 }
        set { root.setInteger("MaxForcePoints", newValue, type: .short) }
    }

    public var minimumOneHitPoint: Bool {
        get { (root.integer("Min1HP") ?? 0) != 0 }
        set { root.setInteger("Min1HP", newValue ? 1 : 0, type: .byte) }
    }

    public var experience: Int {
        get { root.integer("Experience") ?? 0 }
        set { root.setInteger("Experience", newValue, type: .dword) }
    }

    /// Alignment: 0 is the dark side, 100 the light side.
    public var goodEvil: Int {
        get { root.integer("GoodEvil") ?? 50 }
        set { root.setInteger("GoodEvil", min(100, max(0, newValue)), type: .byte) }
    }

    // MARK: Skills

    /// The highest skill rank that can be set: the games read a rank as a signed byte, so
    /// 128–255 are negative ranks (255 is −1). A skill's total with its bonuses is capped at
    /// 127 by the game (The Sith Lords' GetSkillRank), so it can't wrap.
    public static let maximumSkillRank = 127

    /// The stored ranks, as bytes: a rank above `maximumSkillRank` is negative in the game.
    public var skillRanks: [Int] {
        root.list("SkillList")?.map { $0.integer("Rank") ?? 0 } ?? []
    }

    public mutating func setSkillRank(_ skill: Int, _ rank: Int) {
        root.updateList("SkillList", create: true) { list in
            while list.count <= skill { list.append(GFFStruct(id: 0, fields: [GFFField(label: "Rank", value: .byte(0))])) }
            list[skill].setInteger("Rank", min(Self.maximumSkillRank, max(0, rank)), type: .byte)
        }
    }

    // MARK: Feats

    public var feats: [Int] {
        root.list("FeatList")?.compactMap { $0.integer("Feat") } ?? []
    }

    public mutating func addFeats(_ ids: [Int]) {
        root.updateList("FeatList", create: true) { list in
            let template = list.first ?? GFFStruct(id: 1, fields: [GFFField(label: "Feat", value: .word(0))])
            for id in ids where !list.contains(where: { $0.integer("Feat") == id }) {
                var feat = template
                feat.setInteger("Feat", id, type: .word)
                list.append(feat)
            }
        }
    }

    public mutating func removeFeats(_ ids: Set<Int>) {
        root.updateList("FeatList") { list in list.removeAll { ids.contains($0.integer("Feat") ?? -1) } }
    }

    // MARK: Classes and Force powers

    public var classes: [CreatureClass] {
        (root.list("ClassList") ?? []).enumerated().map { index, entry in
            CreatureClass(index: index, classID: entry.integer("Class") ?? 0, level: entry.integer("ClassLevel") ?? 0,
                          powers: entry.list("KnownList0").map { $0.compactMap { $0.integer("Spell") } })
        }
    }

    /// Total character level.
    public var level: Int { classes.reduce(0) { $0 + $1.level } }

    /// The games give a creature at most two classes and ignore further ClassList entries.
    public static let maximumClassCount = 2

    /// Whether `classID` can be added: only as a second class, and not one the creature has
    /// (the games fail to load a creature that lists a class twice).
    public func canAddClass(_ classID: Int) -> Bool {
        classes.count < Self.maximumClassCount && !classes.contains { $0.classID == classID }
    }

    /// Whether class entry `index` can become `classID`: not when the other class already is.
    public func canChangeClass(_ index: Int, to classID: Int) -> Bool {
        classes.indices.contains(index) && !classes.contains { $0.index != index && $0.classID == classID }
    }

    /// The highest level class entry `index` can have without the total level passing `cap`,
    /// the game's level cap; never below the entry's current level or 1.
    public func levelLimit(forClass index: Int, cap: Int) -> Int {
        let others = classes.filter { $0.index != index }.reduce(0) { $0 + $1.level }
        return max(1, classes.first { $0.index == index }?.level ?? 1, cap - others)
    }

    private mutating func updateClass(_ index: Int, _ body: (inout GFFStruct) -> Void) {
        root.updateList("ClassList") { list in
            guard list.indices.contains(index) else { return }
            body(&list[index])
        }
    }

    private static func addPowerLists(_ entry: inout GFFStruct) {
        if !entry.has("SpellsPerDayList") {
            entry["SpellsPerDayList"] = .list([GFFStruct(id: 17767, fields: [GFFField(label: "NumSpellsLeft", value: .byte(0))])])
        }
        if !entry.has("KnownList0") { entry["KnownList0"] = .list([]) }
    }

    public mutating func setClassLevel(_ index: Int, _ level: Int) {
        updateClass(index) { $0.setInteger("ClassLevel", level, type: .short) }
    }

    /// Does nothing when the creature's other class is `classID` (see `canChangeClass`).
    public mutating func changeClass(_ index: Int, to classID: Int, isSpellcaster: Bool) {
        guard canChangeClass(index, to: classID) else { return }
        updateClass(index) { entry in
            entry.setInteger("Class", classID, type: .int)
            if isSpellcaster {
                Self.addPowerLists(&entry)
            } else {
                entry["KnownList0"] = nil
                entry["SpellsPerDayList"] = nil
            }
        }
    }

    /// Adds a class at level 1; does nothing when `canAddClass` is false.
    public mutating func addClass(_ classID: Int, isSpellcaster: Bool) {
        guard canAddClass(classID) else { return }
        root.updateList("ClassList", create: true) { list in
            var entry = GFFStruct(id: 2, fields: [GFFField(label: "Class", value: .int(Int32(clamping: classID))),
                                                  GFFField(label: "ClassLevel", value: .short(1))])
            if isSpellcaster { Self.addPowerLists(&entry) }
            list.append(entry)
        }
    }

    public mutating func removeClass(_ index: Int) {
        root.updateList("ClassList") { list in
            guard list.indices.contains(index) else { return }
            list.remove(at: index)
        }
    }

    /// Gives a class a power list so powers can be added.
    public mutating func enablePowers(classIndex: Int) {
        updateClass(classIndex) { Self.addPowerLists(&$0) }
    }

    public mutating func addPowers(_ ids: [Int], classIndex: Int) {
        updateClass(classIndex) { entry in
            Self.addPowerLists(&entry)
            entry.updateList("KnownList0") { list in
                let template = list.first ?? GFFStruct(id: 3, fields: [GFFField(label: "Spell", value: .word(0))])
                for id in ids where !list.contains(where: { $0.integer("Spell") == id }) {
                    var power = template
                    power.setInteger("Spell", id, type: .word)
                    list.append(power)
                }
            }
        }
    }

    public mutating func removePowers(_ ids: Set<Int>, classIndex: Int) {
        updateClass(classIndex) { entry in
            entry.updateList("KnownList0") { list in list.removeAll { ids.contains($0.integer("Spell") ?? -1) } }
        }
    }

    // MARK: Equipment

    public func equippedItem(_ slot: EquipmentSlot) -> GFFStruct? {
        root.list("Equip_ItemList")?.first { $0.id == slot.rawValue }
    }
}
