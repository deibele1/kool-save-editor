// KSEMac — a KotOR savegame editor for macOS.
// Names, tables, templates and icons read from a game installation, following KSE's
// Pop_KotOR/Pop_TSL, Generate_Master_Item_List and read_global_jrls
// (https://gitlab.com/kotorsge-team/kse). GNU GPL v3 or later.
//
// Unlike KSE, lookups go through chitin.key instead of hard-coded BIF names, every table
// may be overridden from the override folder, and a missing installation degrades to
// numeric labels instead of aborting. Additions: voice sets are named from the talk table,
// include the player's (which TSL's soundset.2da lacks) and can be heard; appearances are
// matched to the portrait showing their face.

import Aurora
import Foundation

public struct ClassInfo: Sendable, Hashable, Identifiable {
    public var id: Int
    public var name: String
    public var isSpellcaster: Bool
}

/// A feat (feat.2da) or Force power (spells.2da).
public struct AbilityInfo: Sendable, Hashable, Identifiable {
    public var id: Int
    public var label: String
    public var name: String
    public var icon: String?
    /// KSE's short list: hides placeholder rows (and, for powers, non-Force spells).
    public var isCommon: Bool
}

public struct BaseItemInfo: Sendable, Hashable {
    public var id: Int
    public var name: String
    public var itemClass: String
    public var equipableSlots: Int
    public var droidOrHuman: Int
    public var isRanged: Bool
    public var stacking: Int
}

public struct QuestInfo: Sendable, Hashable, Identifiable {
    public struct Entry: Sendable, Hashable, Identifiable {
        public var id: Int
        public var text: String
        public var isEnd: Bool

        public init(id: Int, text: String, isEnd: Bool) {
            self.id = id
            self.text = text
            self.isEnd = isEnd
        }
    }

    public var tag: String
    public var name: String
    public var entries: [Entry]
    public var id: String { tag }
}

/// A voice set (soundset.2da row): the sound set file a creature's battle cries, grunts and
/// remarks come from.
public struct SoundsetInfo: Sendable, Hashable, Identifiable {
    public var id: Int
    public var name: String
    /// The sound set file (SSF); nil for rows without one, such as "None".
    public var resRef: String?
    /// The gender.2da value (0 male, 1 female) when the table gives one.
    public var gender: Int?
    /// One of the rows the games give the player character (see `GameData.playerSoundsets`).
    public var isPlayer: Bool
    /// Whether this installation has the sound set file, i.e. whether the voice is heard.
    public var hasSounds: Bool
    /// False for player voice sets the game's soundset.2da lacks.
    public var isInTable: Bool

    /// A companion's voice: the games name their sound sets p_<name>.
    public var isPartyMember: Bool { !isPlayer && resRef?.lowercased().hasPrefix("p_") == true }
}

/// One line of a voice set, ready to play.
public struct VoiceSample: Sendable {
    /// The sound set slot, see `slotName`.
    public var slot: Int
    public var strRef: UInt32
    /// The words spoken, when the talk table has them (grunts have none).
    public var text: String?
    public var audio: [UInt8]
    public var format: GameSound.Format

    public var slotName: String { Self.slotNames[safe: slot] ?? "Sound \(slot + 1)" }

    /// What KotOR's 28 sound set slots are for.
    public static let slotNames = [
        "Battle cry", "Battle cry", "Battle cry", "Battle cry", "Battle cry", "Battle cry", "Selected", "Selected", "Selected",
        "Attack grunt", "Attack grunt", "Attack grunt", "Pain grunt", "Pain grunt", "Low on health", "Knocked out",
        "Critical hit", "Target immune", "Laying a mine", "Disarming a mine", "Stealth", "Searching", "Opening a lock",
        "Lock won’t open", "Lock opened", "Going alone", "Rejoining the party", "Poisoned",
    ]
}

/// The tokens the games fill in when they show text: the player's name, which TSL puts in item
/// names ("<FullName> Crystal"), descriptions and journal entries. Tokens set while playing
/// (<CUSTOM0>, controller buttons) are left as they are.
public struct TextTokens: Sendable, Equatable {
    public var firstName: String
    public var lastName: String

    public init(firstName: String, lastName: String = "") {
        self.firstName = firstName
        self.lastName = lastName
    }

    public var fullName: String { [firstName, lastName].filter { !$0.isEmpty }.joined(separator: " ") }

    public func apply(_ text: String) -> String {
        guard text.contains("<"), !fullName.isEmpty else { return text }
        var result = text
        for (token, value) in [("<FullName>", fullName), ("<PlayerName>", fullName), ("<FirstName>", firstName), ("<LastName>", lastName)] {
            result = result.replacingOccurrences(of: token, with: value, options: .caseInsensitive)
        }
        return result
    }
}

public struct ItemTemplate: Sendable, Hashable, Identifiable {
    public var resRef: String
    public var tag: String
    public var name: String
    public var baseItem: Int
    public var modelVariation: Int
    public var isOverride: Bool
    /// A quest item (the blueprint's plot flag).
    public var isPlot: Bool
    /// The level file (RIM, MOD or ERF) holding the blueprint, for items that aren't in the BIFs
    /// or override folder in this form.
    public var archive: URL?

    /// The level the blueprint comes from, e.g. 401DXN for Modules/401DXN_s.rim.
    public var module: String? {
        guard let name = archive?.deletingPathExtension().lastPathComponent else { return nil }
        return name.lowercased().hasSuffix("_s") ? String(name.dropLast(2)) : name
    }

    /// Level files may reuse a BIF item's name for a different item.
    public var id: String { archive.map { "\(resRef)@\($0.lastPathComponent)" } ?? resRef }
}

public final class GameData: Sendable {
    public let game: Game
    public let root: URL?
    public let encoding: TextEncoding
    public let languageID: UInt32
    public let problem: String?

    public let appearances: [Int: String]
    /// The portrait showing each appearance's face, where the game has one.
    public let appearancePortraits: [Int: String]
    public let portraits: [Int: String]
    public let soundsets: [Int: SoundsetInfo]
    public let genders: [Int: String]
    public let skills: [Int: String]
    public let classes: [Int: ClassInfo]
    public let feats: [Int: AbilityInfo]
    public let powers: [Int: AbilityInfo]
    public let baseItems: [Int: BaseItemInfo]
    public let quests: [String: QuestInfo]
    /// The level cap: the last level exptable.2da gives a reachable XP threshold, else the
    /// game's standard cap.
    public let maximumLevel: Int

    let talkTable: TalkTable?
    let keyArchive: KeyArchive?
    let overrideFolder: URL?
    public let assets: GameAssets

    public var isAvailable: Bool { talkTable != nil && keyArchive != nil }

    /// Loads the tables of the installation at `root`. Never fails: missing or damaged data
    /// yields empty tables and a `problem` description.
    public init(game: Game, root: URL?, encoding override: TextEncoding? = nil) {
        self.game = game
        self.root = root
        var problem: String?
        var talk: TalkTable?
        var key: KeyArchive?
        var overrides: URL?
        if let root {
            do {
                key = try KeyArchive(root: root)
                if let tlk = FileManager.default.caseInsensitiveItem(named: "dialog.tlk", in: root) {
                    talk = try TalkTable(url: tlk, encoding: override)
                } else {
                    problem = "dialog.tlk is missing from \(root.path)."
                }
                overrides = FileManager.default.caseInsensitiveItem(named: "override", in: root)
            } catch {
                problem = error.localizedDescription
            }
        } else {
            problem = "The \(game.title) game folder has not been located."
        }
        talkTable = talk
        keyArchive = key
        overrideFolder = overrides
        languageID = talk?.languageID ?? 0
        encoding = override ?? talk?.encoding ?? .windows1252
        self.problem = problem

        let loader = TableLoader(key: key, overrides: overrides, talk: talk)
        appearances = loader.labels("appearance", column: "label")
        appearancePortraits = loader.appearancePortraits(labels: appearances)
        portraits = loader.labels("portraits", column: "baseresref")
        soundsets = loader.soundsets()
        genders = loader.genders()
        skills = loader.names("skills")
        classes = loader.classes()
        feats = loader.abilities("feat", icon: "icon") { !$0.contains("XXX") }
        powers = loader.abilities("spells", icon: "iconresref") { $0.hasPrefix("FORCE_POWER") && !$0.contains("XXX") }
        baseItems = loader.baseItems()
        quests = loader.quests(encoding: encoding)
        maximumLevel = loader.levelCap() ?? game.maximumLevel
        assets = GameAssets(key: key, overrides: overrides, root: root, talk: talk, encoding: encoding)
    }

    public func string(_ strRef: UInt32) -> String? {
        talkTable?.string(strRef)
    }

    /// The text of a localized string as the game shows it: inline text first, then the talk
    /// table, without {notes}.
    public func text(_ loc: GFFLocString?) -> String? {
        guard let loc else { return nil }
        let raw: String?
        if let inline = loc.text(encoding: encoding, languageID: languageID * 2), !inline.isEmpty {
            raw = inline
        } else {
            raw = loc.hasStringRef ? string(loc.stringRef) : nil
        }
        return raw.map(Self.displayed).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Text as the games show it: they hide notes in {curly braces}, such as the {02} in TSL's
    /// "{02}Padawan Robe" or the voice directions in dialog lines.
    public static func displayed(_ text: String) -> String {
        guard text.contains("{") else { return text }
        return text.replacingOccurrences(of: #"\{[^}]*\}"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    /// Looks a resource up in the override folder, then in the BIF archives.
    public func resource(_ resRef: String, _ type: ResourceType) -> [UInt8]? {
        TableLoader(key: keyArchive, overrides: overrideFolder, talk: talkTable).resource(resRef, type)
    }

    public func itemTemplate(_ resRef: String) -> GFFDocument? {
        resource(resRef, .uti).flatMap { try? GFFDocument(bytes: $0) }
    }

    /// The full blueprint of a catalog entry, read from its level file when it has one.
    public func itemTemplate(_ template: ItemTemplate) -> GFFDocument? {
        guard let archive = template.archive else { return itemTemplate(template.resRef) }
        return (try? openArchiveIndex(at: archive))?.data(for: template.resRef, type: .uti).flatMap { try? GFFDocument(bytes: $0) }
    }

    public func appearanceName(_ id: Int) -> String { appearances[id] ?? "Appearance \(id)" }
    public func portraitName(_ id: Int) -> String { portraits[id] ?? "Portrait \(id)" }
    /// 0xFFFF means no voice set at all; soundset.2da has a separate "None" row.
    public func soundsetName(_ id: Int) -> String { id == 0xFFFF ? "Not set" : soundsets[id]?.name ?? "Voice set \(id)" }
    public func genderName(_ id: Int) -> String { genders[id] ?? "Gender \(id)" }
    public func skillName(_ id: Int) -> String { skills[id] ?? Self.defaultSkills[safe: id] ?? "Skill \(id)" }
    public func className(_ id: Int) -> String { classes[id]?.name ?? "Class \(id)" }
    public func featName(_ id: Int) -> String { feats[id]?.name ?? "Feat \(id)" }
    public func powerName(_ id: Int) -> String { powers[id]?.name ?? "Power \(id)" }
    public func baseItemName(_ id: Int) -> String { baseItems[id]?.name ?? "Base item \(id)" }

    /// The inventory icon texture, `i<itemclass>_<variation>` as KSE builds it.
    public func itemIcon(baseItem: Int, modelVariation: Int) -> String? {
        guard let itemClass = baseItems[baseItem]?.itemClass, !itemClass.isEmpty else { return nil }
        return "i\(itemClass)_" + String(format: "%03d", modelVariation)
    }

    static let defaultSkills = ["Computer Use", "Demolitions", "Stealth", "Awareness", "Persuade", "Repair", "Security", "Treat Injury"]

    /// The voice sets the games give the player character at creation, by gender: KotOR's
    /// Player_Female_W and Player_Male_W rows. The Sith Lords assigns the same rows, but its
    /// soundset.2da stops at row 65, so its player is silent unless a mod adds them back.
    public static let playerSoundsets: [Int: (name: String, gender: Int)] = [83: ("Player - Female", 1), 85: ("Player - Male", 0)]

    /// A random line of a voice set whose sound this installation has; `previous` makes a
    /// different line likelier. Nil when the voice set has no sounds.
    public func randomVoiceSample(soundset id: Int, after previous: VoiceSample? = nil) -> VoiceSample? {
        guard let resRef = soundsets[id]?.resRef, let bytes = resource(resRef, .ssf),
              let set = try? SoundSetFile(bytes: bytes) else { return nil }
        let slots = set.strRefs.prefix(VoiceSample.slotNames.count).enumerated()
            .filter { $0.element != GFFLocString.noStringRef }.shuffled()
        let fresh = slots.filter { $0.element != previous?.strRef }
        for (slot, strRef) in fresh + slots.filter({ $0.element == previous?.strRef }) {
            guard let name = talkTable?.soundResRef(strRef), let file = sound(name), let audio = GameSound.playable(file) else { continue }
            return VoiceSample(slot: slot, strRef: strRef, text: Self.spokenText(string(strRef)), audio: audio.bytes, format: audio.format)
        }
        return nil
    }

    /// A sound file by name: the override folder, the stream folders, then the BIF archives.
    func sound(_ name: String) -> [UInt8]? {
        let fm = FileManager.default
        let streams = ["StreamSounds", "StreamWaves", "StreamVoice"].compactMap { folder in root.flatMap { fm.caseInsensitiveItem(named: folder, in: $0) } }
        for folder in [overrideFolder].compactMap({ $0 }) + streams {
            if let url = fm.caseInsensitiveItem(named: "\(name).wav", in: folder), let data = try? Data(contentsOf: url) { return [UInt8](data) }
        }
        return (try? keyArchive?.resource(name, .wav)) ?? nil
    }

    /// The words of a sound set line. Talk table entries put directions in {braces}; grunts
    /// and placeholders are described in ::colons:: or carry translator notes.
    static func spokenText(_ text: String?) -> String? {
        guard let text else { return nil }
        let words = text.replacingOccurrences(of: #"\{[^}]*\}"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let isDescription = words.contains("::") || ["translate", "grunt"].contains { words.localizedCaseInsensitiveContains($0) }
        return words.isEmpty || isDescription ? nil : words
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

struct TableLoader {
    let key: KeyArchive?
    let overrides: URL?
    let talk: TalkTable?

    func resource(_ resRef: String, _ type: ResourceType) -> [UInt8]? {
        if let overrides, let file = FileManager.default.caseInsensitiveItem(named: "\(resRef).\(type.fileExtension)", in: overrides),
           let data = try? Data(contentsOf: file) {
            return [UInt8](data)
        }
        return (try? key?.resource(resRef, type)) ?? nil
    }

    func contains(_ resRef: String, _ type: ResourceType) -> Bool {
        if key?.contains(resRef, type) == true { return true }
        return overrides.flatMap { FileManager.default.caseInsensitiveItem(named: "\(resRef).\(type.fileExtension)", in: $0) } != nil
    }

    func table(_ name: String) -> TwoDA? {
        resource(name, .twoDA).flatMap { try? TwoDA(bytes: $0) }
    }

    func string(_ cell: String?) -> String? {
        guard let cell, let ref = UInt32(cell), let text = talk?.string(ref).map(GameData.displayed), !text.isEmpty else { return nil }
        return text
    }

    func labels(_ name: String, column: String) -> [Int: String] {
        guard let table = table(name) else { return [:] }
        var result: [Int: String] = [:]
        for row in 0 ..< table.rowCount {
            if let label = table.string(row, column) { result[row] = label }
        }
        return result
    }

    func names(_ name: String) -> [Int: String] {
        guard let table = table(name) else { return [:] }
        var result: [Int: String] = [:]
        for row in 0 ..< table.rowCount {
            if let text = string(table.string(row, "name")) ?? table.string(row, "label") { result[row] = text }
        }
        return result
    }

    /// The portrait showing each appearance's face. portraits.2da names each portrait's
    /// appearances (normal, small and large body); normal bodies are matched first, then the
    /// first portrait wins. Leftovers are matched by name: party appearances to po_p<name> (TSL
    /// lists Bao-Dur's portrait under Atton's appearance and has none for variants such as
    /// Party_NPC_Kreia_Gimped), player bodies to the same body in another size (TSL leaves out
    /// P_MAL_H_LRG_02).
    func appearancePortraits(labels: [Int: String]) -> [Int: String] {
        guard let table = table("portraits") else { return [:] }
        var result: [Int: String] = [:]
        for column in ["appearancenumber", "appearance_s", "appearance_l"] {
            for row in 0 ..< table.rowCount {
                guard let id = table.int(row, column), result[id] == nil, let portrait = table.string(row, "baseresref") else { continue }
                result[id] = portrait
            }
        }
        let names = (0 ..< table.rowCount).compactMap { table.string($0, "baseresref") }
        let byName = Dictionary(names.map { ($0.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        let byLabel = Dictionary(labels.map { ($0.value.lowercased(), $0.key) }, uniquingKeysWith: { first, _ in first })
        let sizes = ["_med_", "_sml_", "_lrg_"]
        for (id, label) in labels.sorted(by: { $0.key < $1.key }) where result[id] == nil {
            let lower = label.lowercased()
            let parts = lower.split(separator: "_")
            if parts.count > 2, parts[0] == "party", parts[1] == "npc" {
                result[id] = byName["po_p\(parts[2])"]
            } else if let size = sizes.first(where: lower.contains) {
                let siblings = sizes.compactMap { byLabel[lower.replacingOccurrences(of: size, with: $0)] }
                let face = siblings.compactMap { result[$0] }.first
                result[id] = face
            }
        }
        return result
    }

    /// Voice sets, named by the talk table (without its "**Do Not Translate This**" notes) or
    /// their label, plus the player voice sets when the table lacks them.
    func soundsets() -> [Int: SoundsetInfo] {
        guard let table = table("soundset") else { return [:] }
        var result: [Int: SoundsetInfo] = [:]
        for row in 0 ..< table.rowCount {
            let spoken = string(table.string(row, "strref")).map {
                $0.replacingOccurrences(of: #"\*\*[^*]*\*\*"#, with: "", options: .regularExpression)
                    .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            }
            guard let name = spoken.flatMap({ $0.isEmpty ? nil : $0 }) ?? table.string(row, "label") else { continue }
            let resRef = table.string(row, "resref")
            result[row] = SoundsetInfo(id: row, name: name, resRef: resRef, gender: table.int(row, "gender"),
                                       isPlayer: GameData.playerSoundsets[row] != nil || resRef?.lowercased().hasPrefix("p_player") == true,
                                       hasSounds: resRef.map { contains($0, .ssf) } ?? false, isInTable: true)
        }
        for (id, player) in GameData.playerSoundsets where result[id] == nil && !result.isEmpty {
            result[id] = SoundsetInfo(id: id, name: player.name, resRef: nil, gender: player.gender, isPlayer: true,
                                      hasSounds: false, isInTable: false)
        }
        return result
    }

    func genders() -> [Int: String] {
        guard let table = table("gender") else { return [:] }
        var result: [Int: String] = [:]
        for row in 0 ..< table.rowCount {
            if let text = string(table.string(row, "name")) {
                result[row] = text
            } else if let constant = table.string(row, "constant") {
                result[row] = constant.replacingOccurrences(of: "GENDER_", with: "").capitalized
            }
        }
        return result
    }

    func classes() -> [Int: ClassInfo] {
        guard let table = table("classes") else { return [:] }
        var result: [Int: ClassInfo] = [:]
        for row in 0 ..< table.rowCount {
            guard let name = string(table.string(row, "name")) ?? table.string(row, "label") else { continue }
            result[row] = ClassInfo(id: row, name: name, isSpellcaster: table.string(row, "spellgaintable") != nil)
        }
        return result
    }

    func abilities(_ name: String, icon: String, common: (String) -> Bool) -> [Int: AbilityInfo] {
        guard let table = table(name) else { return [:] }
        var result: [Int: AbilityInfo] = [:]
        for row in 0 ..< table.rowCount {
            guard let label = table.string(row, "label") else { continue }
            let title = string(table.string(row, "name")) ?? label
            result[row] = AbilityInfo(id: row, label: label, name: title, icon: table.string(row, icon), isCommon: common(label))
        }
        return result
    }

    /// exptable.2da lists the XP each level needs and ends with an unreachable 0xFFFFFFFF row
    /// (level 21 in KotOR, 51 in The Sith Lords); the level before it is the cap.
    func levelCap() -> Int? {
        guard let table = table("exptable") else { return nil }
        let reachable = (0 ..< table.rowCount).compactMap { row -> Int? in
            guard let xp = table.int(row, "xp"), (0 ..< 0xFFFF_FFFF).contains(xp) else { return nil }
            return table.int(row, "level") ?? row + 1
        }
        guard let cap = reachable.max(), cap > 0 else { return nil }
        return cap
    }

    func baseItems() -> [Int: BaseItemInfo] {
        guard let table = table("baseitems") else { return [:] }
        var result: [Int: BaseItemInfo] = [:]
        for row in 0 ..< table.rowCount {
            guard let label = table.string(row, "label") else { continue }
            let ranged = table.columnIndex("rangedweapon") != nil ? table.string(row, "rangedweapon") != nil
                : (table.int(row, "weapontype") ?? 1) != 1
            // Rows without a talk table name show their label, e.g. KotOR's Revan_Armor.
            result[row] = BaseItemInfo(id: row, name: string(table.string(row, "name")) ?? label.replacingOccurrences(of: "_", with: " "),
                                       itemClass: table.string(row, "itemclass") ?? "",
                                       equipableSlots: table.int(row, "equipableslots") ?? 0,
                                       droidOrHuman: table.int(row, "droidorhuman") ?? 0,
                                       isRanged: ranged, stacking: table.int(row, "stacking") ?? 1)
        }
        return result
    }

    func quests(encoding: TextEncoding) -> [String: QuestInfo] {
        guard let bytes = resource("global", .jrl), let journal = try? GFFDocument(bytes: bytes),
              let categories = journal.root.list("Categories") else { return [:] }
        let language = (talk?.languageID ?? 0) * 2
        func text(_ loc: GFFLocString?) -> String? {
            guard let loc else { return nil }
            if let inline = loc.text(encoding: encoding, languageID: language), !inline.isEmpty { return GameData.displayed(inline) }
            return loc.hasStringRef ? talk?.string(loc.stringRef).map(GameData.displayed) : nil
        }
        var result: [String: QuestInfo] = [:]
        for category in categories {
            guard let tag = category.string("Tag", encoding: encoding)?.lowercased(), !tag.isEmpty else { continue }
            let entries = (category.list("EntryList") ?? []).compactMap { entry -> QuestInfo.Entry? in
                guard let id = entry.integer("ID") else { return nil }
                return QuestInfo.Entry(id: id, text: text(entry.locString("Text")) ?? "", isEnd: (entry.integer("End") ?? 0) != 0)
            }
            result[tag] = QuestInfo(tag: tag, name: text(category.locString("Name")) ?? tag, entries: entries)
        }
        return result
    }
}

/// Lazily loaded, cached artwork and the item template catalog.
public actor GameAssets {
    private let key: KeyArchive?
    private let overrides: URL?
    private let root: URL?
    private let talk: TalkTable?
    private let encoding: TextEncoding
    private var textures: ERFIndex??
    private var images: [String: RGBAImage] = [:]
    private var missing: Set<String> = []
    private var templates: [ItemTemplate]?

    init(key: KeyArchive?, overrides: URL?, root: URL?, talk: TalkTable?, encoding: TextEncoding) {
        self.key = key
        self.overrides = overrides
        self.root = root
        self.talk = talk
        self.encoding = encoding
    }

    /// A GUI texture (portrait, feat/power or item icon) from the override folder or
    /// TexturePacks/swpc_tex_gui.erf.
    public func image(_ resRef: String) -> RGBAImage? {
        let name = resRef.lowercased()
        if let cached = images[name] { return cached }
        if missing.contains(name) { return nil }
        let loader = TableLoader(key: key, overrides: overrides, talk: talk)
        var image: RGBAImage?
        if let overrides, let tga = FileManager.default.caseInsensitiveItem(named: "\(name).tga", in: overrides),
           let data = try? Data(contentsOf: tga) {
            image = try? TGADecoder.decode([UInt8](data))
        }
        if image == nil, let tpc = loader.resource(name, .tpc) ?? guiTextures()?.data(for: name, type: .tpc) {
            image = try? TPCDecoder.decode(tpc)
        }
        if let image { images[name] = image } else { missing.insert(name) }
        return image
    }

    private func guiTextures() -> ERFIndex? {
        if let textures { return textures }
        let pack = root.flatMap { FileManager.default.caseInsensitiveItem(path: "TexturePacks/swpc_tex_gui.erf", in: $0) }
        let index = pack.flatMap { try? ERFIndex(url: $0) }
        textures = .some(index)
        return index
    }

    /// Every item blueprint: the BIFs, the override folder (which replaces BIF blueprints of
    /// the same name) and the level files, which hold the unique items found in one place and
    /// sometimes reuse a name for a different item. Copies that are the same item to a player
    /// are listed once (see `signature`).
    public func itemTemplates() -> [ItemTemplate] {
        if let templates { return templates }
        typealias Parsed = (template: ItemTemplate, signature: String)
        func parse(_ resRef: String, _ bytes: [UInt8], override: Bool = false, archive: URL? = nil) -> Parsed? {
            guard let document = try? GFFDocument(bytes: bytes) else { return nil }
            let root = document.root
            let loc = root.locString("LocalizedName")
            var name = loc?.text(encoding: encoding, languageID: (talk?.languageID ?? 0) * 2) ?? ""
            if name.isEmpty, let loc, loc.hasStringRef { name = talk?.string(loc.stringRef) ?? "" }
            name = GameData.displayed(name)
            let template = ItemTemplate(resRef: resRef.lowercased(), tag: root.string("Tag", encoding: encoding) ?? "", name: name,
                                        baseItem: root.integer("BaseItem") ?? 0,
                                        modelVariation: root.integer("ModelVariation") ?? root.integer("TextureVar") ?? 0,
                                        isOverride: override, isPlot: (root.integer("Plot") ?? 0) != 0, archive: archive)
            return (template, Self.signature(root, name: name))
        }
        var global: [String: Parsed] = [:]
        if let key {
            for entry in key.entries(of: .uti) {
                if let bytes = try? key.resource(entry.resRef, .uti), let parsed = parse(entry.resRef, bytes) { global[parsed.template.resRef] = parsed }
            }
        }
        if let overrides, let files = try? FileManager.default.contentsOfDirectory(at: overrides, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension.lowercased() == "uti" {
                if let data = try? Data(contentsOf: file), let parsed = parse(file.deletingPathExtension().lastPathComponent, [UInt8](data), override: true) {
                    global[parsed.template.resRef] = parsed
                }
            }
        }
        var found = global.values.map(\.template)
        var signatures = Set(global.values.map(\.signature))
        for archive in levelArchives() {
            guard let index = try? openArchiveIndex(at: archive) else { continue }
            for entry in index.entries where entry.type == .uti {
                guard let bytes = index.data(for: entry.resRef, type: .uti), let parsed = parse(entry.resRef, bytes, archive: archive),
                      signatures.insert(parsed.signature).inserted else { continue }
                found.append(parsed.template)
            }
        }
        let sorted = found.sorted { ($0.resRef, $0.archive == nil ? "" : $0.id) < ($1.resRef, $1.archive == nil ? "" : $1.id) }
        templates = sorted
        return sorted
    }

    /// What makes two blueprints the same item to a player: the displayed name, the tag and
    /// every field except price, descriptions, the plot, stolen and identified flags, stack size
    /// and developer notes. Level files carry many copies differing only in those.
    static func signature(_ root: GFFStruct, name: String) -> String {
        let ignored: Set<String> = ["LocalizedName", "Description", "DescIdentified", "Tag", "TemplateResRef", "Cost", "AddCost",
                                    "Plot", "Stolen", "Identified", "StackSize", "Comment", "PaletteID"]
        let fields = root.fields.filter { !ignored.contains($0.label) }.sorted { $0.label < $1.label }.map { "\($0.label)=\($0.value)" }
        return ([name.lowercased(), (root.string("Tag") ?? "").lowercased()] + fields).joined(separator: "\u{1F}")
    }

    /// The level files: Modules/ (RIM, MOD and ERF) and KotOR's rims/, in name order.
    private func levelArchives() -> [URL] {
        guard let root else { return [] }
        let fm = FileManager.default
        return ["Modules", "rims"].compactMap { fm.caseInsensitiveItem(named: $0, in: root) }.flatMap { folder in
            ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
                .filter { ["rim", "mod", "erf"].contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent.lowercased() < $1.lastPathComponent.lowercased() }
        }
    }
}
