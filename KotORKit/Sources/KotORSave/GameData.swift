// KSEMac — a KotOR savegame editor for macOS.
// Names, tables, templates and icons read from a game installation, following KSE's
// Pop_KotOR/Pop_TSL, Generate_Master_Item_List and read_global_jrls
// (https://gitlab.com/kotorsge-team/kse). GNU GPL v3 or later.
//
// Unlike KSE, lookups go through chitin.key instead of hard-coded BIF names, every table
// may be overridden from the override folder, and a missing installation degrades to
// numeric labels instead of aborting.

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

public struct ItemTemplate: Sendable, Hashable, Identifiable {
    public var resRef: String
    public var tag: String
    public var name: String
    public var baseItem: Int
    public var modelVariation: Int
    public var isOverride: Bool
    public var id: String { resRef }
}

public final class GameData: Sendable {
    public let game: Game
    public let root: URL?
    public let encoding: TextEncoding
    public let languageID: UInt32
    public let problem: String?

    public let appearances: [Int: String]
    public let portraits: [Int: String]
    public let soundsets: [Int: String]
    public let genders: [Int: String]
    public let skills: [Int: String]
    public let classes: [Int: ClassInfo]
    public let feats: [Int: AbilityInfo]
    public let powers: [Int: AbilityInfo]
    public let baseItems: [Int: BaseItemInfo]
    public let quests: [String: QuestInfo]

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
        portraits = loader.labels("portraits", column: "baseresref")
        soundsets = loader.labels("soundset", column: "label")
        genders = loader.genders()
        skills = loader.names("skills")
        classes = loader.classes()
        feats = loader.abilities("feat", icon: "icon") { !$0.contains("XXX") }
        powers = loader.abilities("spells", icon: "iconresref") { $0.hasPrefix("FORCE_POWER") && !$0.contains("XXX") }
        baseItems = loader.baseItems()
        quests = loader.quests(encoding: encoding)
        assets = GameAssets(key: key, overrides: overrides, root: root, talk: talk, encoding: encoding)
    }

    public func string(_ strRef: UInt32) -> String? {
        talkTable?.string(strRef)
    }

    /// The text of a localized string: inline text first, then the talk table.
    public func text(_ loc: GFFLocString?) -> String? {
        guard let loc else { return nil }
        if let inline = loc.text(encoding: encoding, languageID: languageID * 2), !inline.isEmpty { return inline }
        return loc.hasStringRef ? string(loc.stringRef) : nil
    }

    /// Looks a resource up in the override folder, then in the BIF archives.
    public func resource(_ resRef: String, _ type: ResourceType) -> [UInt8]? {
        TableLoader(key: keyArchive, overrides: overrideFolder, talk: talkTable).resource(resRef, type)
    }

    public func itemTemplate(_ resRef: String) -> GFFDocument? {
        resource(resRef, .uti).flatMap { try? GFFDocument(bytes: $0) }
    }

    public func appearanceName(_ id: Int) -> String { appearances[id] ?? "Appearance \(id)" }
    public func portraitName(_ id: Int) -> String { portraits[id] ?? "Portrait \(id)" }
    public func soundsetName(_ id: Int) -> String { id == 0xFFFF ? "None" : soundsets[id] ?? "Soundset \(id)" }
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

    func table(_ name: String) -> TwoDA? {
        resource(name, .twoDA).flatMap { try? TwoDA(bytes: $0) }
    }

    func string(_ cell: String?) -> String? {
        guard let cell, let ref = UInt32(cell), let text = talk?.string(ref), !text.isEmpty else { return nil }
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

    func baseItems() -> [Int: BaseItemInfo] {
        guard let table = table("baseitems") else { return [:] }
        var result: [Int: BaseItemInfo] = [:]
        for row in 0 ..< table.rowCount {
            guard let label = table.string(row, "label") else { continue }
            let ranged = table.columnIndex("rangedweapon") != nil ? table.string(row, "rangedweapon") != nil
                : (table.int(row, "weapontype") ?? 1) != 1
            result[row] = BaseItemInfo(id: row, name: string(table.string(row, "name")) ?? label,
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
            if let inline = loc.text(encoding: encoding, languageID: language), !inline.isEmpty { return inline }
            return loc.hasStringRef ? talk?.string(loc.stringRef) : nil
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

    /// Every item blueprint in the game (templates BIF) and override folder.
    public func itemTemplates() -> [ItemTemplate] {
        if let templates { return templates }
        var byResRef: [String: ItemTemplate] = [:]
        func add(_ resRef: String, _ bytes: [UInt8], override: Bool) {
            guard let gff = try? GFFDocument(bytes: bytes) else { return }
            let root = gff.root
            let loc = root.locString("LocalizedName")
            var name = loc?.text(encoding: encoding, languageID: (talk?.languageID ?? 0) * 2) ?? ""
            if name.isEmpty, let loc, loc.hasStringRef { name = talk?.string(loc.stringRef) ?? "" }
            byResRef[resRef.lowercased()] = ItemTemplate(
                resRef: resRef.lowercased(), tag: root.string("Tag", encoding: encoding) ?? "", name: name,
                baseItem: root.integer("BaseItem") ?? 0,
                modelVariation: root.integer("ModelVariation") ?? root.integer("TextureVar") ?? 0, isOverride: override)
        }
        if let key {
            for entry in key.entries(of: .uti) {
                if let bytes = try? key.resource(entry.resRef, .uti) { add(entry.resRef, bytes, override: false) }
            }
        }
        if let overrides, let files = try? FileManager.default.contentsOfDirectory(at: overrides, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension.lowercased() == "uti" {
                if let data = try? Data(contentsOf: file) {
                    add(file.deletingPathExtension().lastPathComponent, [UInt8](data), override: true)
                }
            }
        }
        let sorted = byResRef.values.sorted { $0.resRef < $1.resRef }
        templates = sorted
        return sorted
    }
}
