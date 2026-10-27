// Builders for synthetic KotOR files, saves and game installations used by the tests.

import Aurora
import Foundation

public func gffStruct(_ id: UInt32 = 0, _ fields: KeyValuePairs<String, GFFValue>) -> GFFStruct {
    GFFStruct(id: id, fields: fields.map { GFFField(label: $0.key, value: $0.value) })
}

public func loc(_ text: String? = nil, strRef: UInt32 = GFFLocString.noStringRef) -> GFFValue {
    .locString(GFFLocString(stringRef: strRef, substrings: text.map { [.init(languageID: 0, bytes: TextEncoding.windows1252.encode($0))] } ?? []))
}

public func temporaryDirectory(_ name: String = #function) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("KSEMacTests-\(name.filter(\.isLetter))-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// MARK: - Binary formats

public func binary2DA(columns: [String], rows: [[String]]) -> [UInt8] {
    var out = BinaryWriter()
    out.write(contentsOf: Array("2DA V2.b\n".utf8))
    for column in columns {
        out.write(contentsOf: Array(column.utf8))
        out.write(UInt8(0x09))
    }
    out.write(UInt8(0))
    out.write(UInt32(rows.count))
    for index in rows.indices {
        out.write(contentsOf: Array(String(index).utf8))
        out.write(UInt8(0x09))
    }
    var data: [UInt8] = []
    var offsets: [String: Int] = [:]
    for row in rows {
        for column in columns.indices {
            let cell = column < row.count ? row[column] : ""
            if offsets[cell] == nil {
                offsets[cell] = data.count
                data += Array(cell.utf8) + [0]
            }
            out.write(UInt16(offsets[cell]!))
        }
    }
    out.write(UInt16(data.count))
    out.write(contentsOf: data)
    return out.bytes
}

public func talkTable(_ strings: [String], language: UInt32 = 0, encoding: TextEncoding = .windows1252) -> [UInt8] {
    let encoded = strings.map { encoding.encode($0) }
    var out = BinaryWriter()
    out.writeTag("TLK ")
    out.writeTag("V3.0")
    out.write(language)
    out.write(UInt32(strings.count))
    out.write(UInt32(20 + 40 * strings.count))
    var offset = 0
    for text in encoded {
        out.write(UInt32(text.isEmpty ? 0 : 1))
        out.writeZeros(16 + 8)
        out.write(UInt32(offset))
        out.write(UInt32(text.count))
        out.write(Float(0))
        offset += text.count
    }
    for text in encoded { out.write(contentsOf: text) }
    return out.bytes
}

public struct KeyEntry {
    public var resRef: String
    public var type: ResourceType
    public var bif: Int
    public var index: Int

    public init(_ resRef: String, _ type: ResourceType, bif: Int, index: Int) {
        self.resRef = resRef
        self.type = type
        self.bif = bif
        self.index = index
    }
}

public func keyFile(bifs: [String], entries: [KeyEntry]) -> [UInt8] {
    var out = BinaryWriter()
    out.writeTag("KEY ")
    out.writeTag("V1  ")
    let fileTable = 64
    let names = bifs.map { Array($0.utf8) + [0] }
    let keyTable = fileTable + bifs.count * 12 + names.reduce(0) { $0 + $1.count }
    out.write(UInt32(bifs.count))
    out.write(UInt32(entries.count))
    out.write(UInt32(fileTable))
    out.write(UInt32(keyTable))
    out.write(UInt32(124))
    out.write(UInt32(1))
    out.writeZeros(32)
    var nameOffset = fileTable + bifs.count * 12
    for name in names {
        out.write(UInt32(0))
        out.write(UInt32(nameOffset))
        out.write(UInt16(name.count))
        out.write(UInt16(1))
        nameOffset += name.count
    }
    for name in names { out.write(contentsOf: name) }
    for entry in entries {
        out.writeFixed(Array(entry.resRef.utf8), length: 16)
        out.write(entry.type.rawValue)
        out.write(UInt32(entry.bif << 20 | entry.index))
    }
    return out.bytes
}

public func bifFile(_ resources: [(type: ResourceType, data: [UInt8])]) -> [UInt8] {
    var out = BinaryWriter()
    out.writeTag("BIFF")
    out.writeTag("V1  ")
    out.write(UInt32(resources.count))
    out.write(UInt32(0))
    out.write(UInt32(20))
    var offset = 20 + resources.count * 16
    for (index, resource) in resources.enumerated() {
        out.write(UInt32(index))
        out.write(UInt32(offset))
        out.write(UInt32(resource.data.count))
        out.write(UInt32(resource.type.rawValue))
        offset += resource.data.count
    }
    for resource in resources { out.write(contentsOf: resource.data) }
    return out.bytes
}

/// An uncompressed RGBA TPC; `rows` are given top-down and stored bottom-up like the game.
public func tpcRGBA(width: Int, height: Int, rowsTopDown: [[UInt8]]) -> [UInt8] {
    var out = BinaryWriter()
    out.write(UInt32(0))
    out.write(Float(1))
    out.write(UInt16(width))
    out.write(UInt16(height))
    out.write(UInt8(4))
    out.write(UInt8(1))
    out.writeZeros(114)
    for row in rowsTopDown.reversed() { out.write(contentsOf: row) }
    return out.bytes
}

// MARK: - Saves

public enum SaveFixture {
    public static let moduleName = "test_m01"

    public static func creature(name: String, player: Bool, tsl: Bool) -> GFFStruct {
        var fields: [GFFField] = []
        if player { fields.append(GFFField(label: "Mod_FirstName", value: loc(name))) }
        let base = gffStruct(player ? 48813 : 0xFFFF_FFFF, [
            "FirstName": loc(name), "LastName": loc(), "Tag": .string(player ? "" : name.lowercased()),
            "Gender": .byte(0), "Str": .byte(14), "Dex": .byte(16), "Con": .byte(12), "Int": .byte(10),
            "Wis": .byte(11), "Cha": .byte(13), "SoundSetFile": .word(1), "Min1HP": .byte(0),
            "HitPoints": .short(30), "CurrentHitPoints": .short(25), "MaxHitPoints": .short(40),
            "PregameCurrent": .short(40), "ForcePoints": .short(10), "CurrentForce": .short(5),
            "MaxForcePoints": .short(12), "Experience": .dword(12_000), "PortraitId": .word(0), "GoodEvil": .byte(60),
            "Appearance_Type": .word(1),
            "ClassList": .list([
                gffStruct(2, ["Class": .int(0), "ClassLevel": .short(5)]),
                gffStruct(2, ["Class": .int(3), "ClassLevel": .short(2),
                              "SpellsPerDayList": .list([gffStruct(17767, ["NumSpellsLeft": .byte(0)])]),
                              "KnownList0": .list([gffStruct(3, tsl ? ["Spell": .word(0), "SpellFlags": .byte(1), "SpellMetaMagic": .byte(0)] : ["Spell": .word(0)])])]),
            ]),
            "SkillList": .list((0 ..< 8).map { gffStruct(0, ["Rank": .byte(UInt8($0))]) }),
            "FeatList": .list([gffStruct(1, ["Feat": .word(0)]), gffStruct(1, ["Feat": .word(2)])]),
            "CombatInfo": .structure(gffStruct(51882, ["LeftEquip": .dword(0x7F00_0000), "RightEquip": .dword(228),
                                                         "LeftString": .string(""), "RightString": .string("Blaster Rifle")])),
            "Equip_ItemList": .list([gffStruct(16, ["ObjectId": .dword(228), "BaseItem": .int(0), "Tag": .string("g_w_blstrrfl001"),
                                                    "LocalizedName": loc(strRef: 8), "StackSize": .word(1), "ModelVariation": .byte(1),
                                                    "XOrientation": .float(1)])]),
            "XPosition": .float(110.14026), "YOrientation": .float(-0.00012031396),
        ])
        fields += base.fields
        return GFFStruct(id: base.id, fields: fields)
    }

    public static func item(_ tag: String, name: String, stack: Int, baseItem: Int = 1) -> GFFStruct {
        gffStruct(0, ["BaseItem": .int(Int32(baseItem)), "Tag": .string(tag), "Identified": .byte(1), "LocalizedName": loc(name),
                      "StackSize": .word(UInt16(stack)), "ModelVariation": .byte(1), "PropertiesList": .list([]),
                      "XOrientation": .float(1), "NewItem": .byte(0)])
    }

    /// Writes a complete, minimal save folder.
    public static func write(to folder: URL, tsl: Bool = false, signatures: Bool = false) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var info = GFFDocument(fileType: "NFO ")
        info.root = gffStruct(0xFFFF_FFFF, ["AREANAME": .string("Test Area"), "LASTMODULE": .string(moduleName),
                                             "TIMEPLAYED": .dword(3725), "CHEATUSED": .byte(0), "SAVEGAMENAME": .string("Fixture"),
                                             "PORTRAIT0": .resRef("po_test")])
        if tsl { info.root["PCNAME"] = .string("Hero") }

        let npcCount = tsl ? 12 : 9
        var party = GFFDocument(fileType: "PT  ")
        party.root = gffStruct(0xFFFF_FFFF, [
            "PT_GOLD": .dword(100), "PT_XP_POOL": .int(50), "PT_PLAYEDSECONDS": .dword(3725), "PT_CONTROLLED_NP": .int(2),
            "PT_CHEAT_USED": .byte(0), "PT_NUM_MEMBERS": .byte(1),
            "PT_MEMBERS": .list([gffStruct(0, ["PT_MEMBER_ID": .int(2), "PT_IS_LEADER": .byte(0)])]),
            "PT_AVAIL_NPCS": .list((0 ..< npcCount).map { gffStruct(0, ["PT_NPC_AVAIL": .byte($0 == 0 || $0 == 2 ? 1 : 0), "PT_NPC_SELECT": .byte(1)]) }),
            "JNL_Entries": .list([gffStruct(0, ["JNL_PlotID": .string("q_one"), "JNL_State": .int(10), "JNL_Date": .dword(1), "JNL_Time": .dword(100)])]),
        ])
        if tsl {
            party.root["PT_PCNAME"] = .string("Hero")
            party.root["PT_ITEM_COMPONEN"] = .dword(7)
            party.root["PT_ITEM_CHEMICAL"] = .dword(9)
            party.root["PT_INFLUENCE"] = .list((0 ..< 10).map { gffStruct(0, ["PT_NPC_INFLUENCE": .int(Int32(40 + $0))]) })
        }

        var globals = GFFDocument(fileType: "GVT ")
        globals.root = gffStruct(0xFFFF_FFFF, [
            "CatBoolean": .list(["Bool_A", "Bool_B", "Bool_C"].map { gffStruct(0, ["Name": .string($0)]) }),
            "CatNumber": .list(["Num_A", "Num_B"].map { gffStruct(0, ["Name": .string($0)]) }),
            "CatString": .list([gffStruct(0, ["Name": .string("Str_A")])]),
            "ValBoolean": .void([0b1010_0000]), "ValNumber": .void([5, 200]),
            "ValString": .list([gffStruct(0, ["String": .string("abc")])]),
        ])

        var module = GFFDocument(fileType: "IFO ")
        module.root = gffStruct(0xFFFF_FFFF, ["Mod_NextObjId0": .dword(500), "Mod_Tag": .string(""),
                                               "Mod_PlayerList": .list([creature(name: "Hero", player: true, tsl: tsl)])])
        var git = GFFDocument(fileType: "GIT ")
        git.root = gffStruct(0xFFFF_FFFF, ["Creature List": .list([])])
        let inner = ERFArchive(fileType: "MOD ", resources: [
            .init(resRef: "m01", type: .git, resID: 0, data: git.encoded()),
            .init(resRef: "Module", type: .ifo, resID: 1, data: module.encoded()),
        ])

        var inventory = GFFDocument(fileType: "INV ")
        inventory.root = gffStruct(0xFFFF_FFFF, ["ItemList": .list([
            item("g_i_medeqpmnt01", name: "Medpac", stack: 3),
            item("g_i_medeqpmnt01", name: "Medpac", stack: 5),
            item("g_w_lngswrd01", name: "Long Sword", stack: 1, baseItem: 2),
        ])])

        func npc(_ name: String) -> [UInt8] {
            var utc = GFFDocument(fileType: "UTC ")
            utc.root = creature(name: name, player: false, tsl: tsl)
            return utc.encoded()
        }
        var repute = GFFDocument(fileType: "FAC ")
        repute.root = gffStruct(0xFFFF_FFFF, ["FactionList": .list([])])

        var archive = ERFArchive(fileType: "MOD ", resources: [
            .init(resRef: "AVAILNPC0", type: .utc, resID: 0, data: npc("Bastila")),
            .init(resRef: "AVAILNPC2", type: .utc, resID: 1, data: npc("Carth")),
            .init(resRef: "INVENTORY", type: .res, resID: 2, data: inventory.encoded()),
            .init(resRef: "REPUTE", type: .fac, resID: 3, data: repute.encoded()),
            .init(resRef: "other_m00", type: .sav, resID: 4, data: Array(repeating: 0xAB, count: 64)),
            .init(resRef: moduleName, type: .sav, resID: 5, data: inner.encoded()),
        ])
        archive.buildYear = 124
        archive.buildDay = 345

        try Data(info.encoded()).write(to: folder.appendingPathComponent("savenfo.res"))
        try Data(party.encoded()).write(to: folder.appendingPathComponent("PARTYTABLE.res"))
        try Data(globals.encoded()).write(to: folder.appendingPathComponent("GLOBALVARS.res"))
        try Data(archive.encoded()).write(to: folder.appendingPathComponent("SAVEGAME.sav"))
        var screen = [UInt8](repeating: 0, count: 18)
        screen[2] = 2
        screen[12] = 2; screen[14] = 1; screen[16] = 24
        screen += [10, 20, 30, 40, 50, 60]
        try Data(screen).write(to: folder.appendingPathComponent("Screen.tga"))
        if signatures {
            for name in ["SAVE_PARTY.sig", "SAVE_VARS.sig", "SAVE_INFO.sig", "Screen.sig", "SAVE_HEADERVAR.sig", "SAVE_DATA.sig"] {
                try Data(repeating: 0, count: 20).write(to: folder.appendingPathComponent(name))
            }
        }
    }
}

// MARK: - Game installation

public enum GameInstallFixture {
    public static let strings = [
        "Male", "Female", "Soldier", "Scout", "Jedi Guardian", "Flurry", "Power Attack", "Force Push",
        "Blaster Rifle", "Medpac", "Computer Use", "Demolitions", "Stealth", "Awareness", "Persuade", "Repair",
        "Security", "Treat Injury", "Quest One", "The quest begins.", "The quest is done.", "Rifle", "Medical", "Armor",
        "Quite élégant",
    ]

    /// Writes chitin.key, data/*.bif, dialog.tlk, an override folder and a GUI texture pack.
    public static func write(to root: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("Data"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("Override"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("TexturePacks"), withIntermediateDirectories: true)

        let tables: [(String, [UInt8])] = [
            ("appearance", binary2DA(columns: ["label"], rows: [["PMBTest"], ["PFBTest"]])),
            ("portraits", binary2DA(columns: ["baseresref"], rows: [["po_test"], ["po_other"]])),
            ("soundset", binary2DA(columns: ["label"], rows: [["Player Male"], ["Player Female"]])),
            ("gender", binary2DA(columns: ["name", "constant"], rows: [["0", "GENDER_MALE"], ["1", "GENDER_FEMALE"], ["", "GENDER_BOTH"]])),
            ("skills", binary2DA(columns: ["label", "name"], rows: (0 ..< 8).map { ["SKILL\($0)", String(10 + $0)] })),
            ("classes", binary2DA(columns: ["label", "name", "spellgaintable"],
                                  rows: [["Soldier", "2", ""], ["Scout", "3", ""], ["Scoundrel", "", ""], ["JediGuardian", "4", "CLS_SPGN_JEDI"]])),
            ("feat", binary2DA(columns: ["label", "name", "icon"],
                               rows: [["FEAT_FLURRY", "5", "ip_flurry"], ["FEAT_XXX_UNUSED", "", ""], ["FEAT_POWER_ATTACK", "6", "ip_powattack"]])),
            ("spells", binary2DA(columns: ["label", "name", "iconresref"],
                                 rows: [["FORCE_POWER_PUSH", "7", "ip_push"], ["ITEM_ABILITY_SPEED", "", ""]])),
            ("baseitems", binary2DA(columns: ["label", "name", "itemclass", "equipableslots", "droidorhuman", "weapontype", "rangedweapon", "stacking"],
                                    rows: [["BlasterRifle", "21", "w_brifle", "0x00010", "1", "4", "1", "1"],
                                           ["Medpac", "22", "i_medeqpmnt", "0x00000", "0", "", "", "10"],
                                           ["LongSword", "", "w_lsword", "0x00030", "1", "1", "", "1"],
                                           ["Armor", "23", "a_class4", "0x00002", "1", "", "", "1"]])),
        ]

        func uti(_ tag: String, strRef: UInt32, baseItem: Int32, stack: UInt16 = 1) -> [UInt8] {
            var doc = GFFDocument(fileType: "UTI ")
            doc.root = gffStruct(0xFFFF_FFFF, ["TemplateResRef": .resRef(tag), "BaseItem": .int(baseItem), "LocalizedName": loc(strRef: strRef),
                                               "Description": loc(), "DescIdentified": loc(), "Tag": .string(tag), "Charges": .byte(0),
                                               "Cost": .dword(10), "Stolen": .byte(0), "StackSize": .word(stack), "Plot": .byte(0),
                                               "AddCost": .dword(0), "Identified": .byte(1), "ModelVariation": .byte(1),
                                               "PropertiesList": .list([gffStruct(0, ["PropertyName": .word(1)])]), "Comment": .string("")])
            return doc.encoded()
        }
        let templates: [(String, [UInt8])] = [
            ("g_w_blstrrfl001", uti("g_w_blstrrfl001", strRef: 8, baseItem: 0)),
            ("g_i_medeqpmnt01", uti("g_i_medeqpmnt01", strRef: 9, baseItem: 1)),
        ]

        var journal = GFFDocument(fileType: "JRL ")
        journal.root = gffStruct(0xFFFF_FFFF, ["Categories": .list([
            gffStruct(0, ["Name": loc(strRef: 18), "Tag": .string("q_one"), "EntryList": .list([
                gffStruct(0, ["ID": .dword(10), "Text": loc(strRef: 19), "End": .word(0)]),
                gffStruct(1, ["ID": .dword(20), "Text": loc(strRef: 20), "End": .word(1)]),
            ])]),
            gffStruct(1, ["Name": loc("Inline Quest"), "Tag": .string("Q_Two"), "EntryList": .list([
                gffStruct(0, ["ID": .dword(5), "Text": loc("Started"), "End": .word(0)]),
            ])]),
        ])])

        var entries: [KeyEntry] = []
        for (index, table) in tables.enumerated() { entries.append(KeyEntry(table.0, .twoDA, bif: 0, index: index)) }
        for (index, template) in templates.enumerated() { entries.append(KeyEntry(template.0, .uti, bif: 1, index: index)) }
        entries.append(KeyEntry("global", .jrl, bif: 2, index: 0))

        try Data(keyFile(bifs: ["data\\2da.bif", "data\\templates.bif", "data\\dialogs.bif"], entries: entries))
            .write(to: root.appendingPathComponent("chitin.key"))
        try Data(bifFile(tables.map { (ResourceType.twoDA, $0.1) })).write(to: root.appendingPathComponent("Data/2DA.bif"))
        try Data(bifFile(templates.map { (ResourceType.uti, $0.1) })).write(to: root.appendingPathComponent("Data/Templates.bif"))
        try Data(bifFile([(.jrl, journal.encoded())])).write(to: root.appendingPathComponent("Data/dialogs.bif"))
        try Data(talkTable(strings)).write(to: root.appendingPathComponent("dialog.tlk"))

        var custom = GFFDocument(fileType: "UTI ")
        custom.root = gffStruct(0xFFFF_FFFF, ["BaseItem": .int(1), "Tag": .string("custom_item"), "LocalizedName": loc("Custom Thing"),
                                              "StackSize": .word(1), "Cost": .dword(1)])
        try Data(custom.encoded()).write(to: root.appendingPathComponent("Override/custom_item.uti"))
        try Data(binary2DA(columns: ["label"], rows: [["PMBOverride"], ["PFBTest"], ["Extra"]]))
            .write(to: root.appendingPathComponent("Override/appearance.2da"))

        let red: [UInt8] = [255, 0, 0, 255], blue: [UInt8] = [0, 0, 255, 255]
        let pack = ERFArchive(fileType: "ERF ", resources: [
            .init(resRef: "po_test", type: .tpc, resID: 0, data: tpcRGBA(width: 2, height: 2, rowsTopDown: [red + red, blue + blue])),
            .init(resRef: "ip_flurry", type: .tpc, resID: 1, data: tpcRGBA(width: 1, height: 1, rowsTopDown: [blue])),
        ])
        try Data(pack.encoded()).write(to: root.appendingPathComponent("TexturePacks/swpc_tex_gui.erf"))
    }
}
