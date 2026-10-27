// KSEMac — a KotOR savegame editor for macOS.
// Builds inventory/equipment item structs from .uti blueprints, after KSE's
// SpawnAddInventoryWidgets and Populate_EquipTables (https://gitlab.com/kotorsge-team/kse).
// GNU GPL v3 or later.
//
// Fixes relative to KSE: TSL-only upgrade fields are no longer added to KotOR items (a
// Perl precedence bug made the check always true); blueprint fields that are absent are
// defaulted instead of duplicating the struct's first field; replacing equipment no
// longer writes undefined UpgradeSlot values.

import Aurora
import Foundation

enum ItemFactory {
    static func inventoryItem(from template: GFFDocument, game: Game, stackSize: Int) -> GFFStruct {
        var item = GFFStruct(id: 0, fields: fields(from: template.root, game: game))
        item.setInteger("StackSize", max(1, stackSize), type: .word)
        return item
    }

    static func equippedItem(from template: GFFDocument, game: Game, slot: EquipmentSlot, objectID: UInt32) -> GFFStruct {
        var item = GFFStruct(id: slot.rawValue, fields: [GFFField(label: "ObjectId", value: .dword(objectID))]
            + fields(from: template.root, game: game))
        item.setInteger("NewItem", 0, type: .byte)
        return item
    }

    /// The fields of an item instance, in the order the game writes them.
    static func fields(from uti: GFFStruct, game: Game) -> [GFFField] {
        var fields: [GFFField] = []
        func copy(_ label: String, default value: GFFValue) {
            fields.append(GFFField(label: label, value: uti[label] ?? value))
        }
        func set(_ label: String, _ value: GFFValue) {
            fields.append(GFFField(label: label, value: value))
        }

        copy("BaseItem", default: .int(0))
        copy("Tag", default: .exoString([]))
        set("Identified", .byte(1))
        copy("Description", default: .locString(GFFLocString()))
        copy("DescIdentified", default: .locString(GFFLocString()))
        copy("LocalizedName", default: .locString(GFFLocString()))
        copy("StackSize", default: .word(1))
        copy("Stolen", default: .byte(0))
        set("Upgrades", .dword(0))
        if game.hasItemUpgradeSlots {
            set("UpgradeLevel", .byte(UInt8(clamping: uti.integer("UpgradeLevel") ?? 0)))
            for slot in 0 ..< 6 { set("UpgradeSlot\(slot)", .int(-1)) }
        }
        set("Dropable", .byte(1))
        set("Pickpocketable", .byte(1))
        copy("ModelVariation", default: .byte(1))
        for optional in ["BodyVariation", "TextureVar"] {
            if let value = uti[optional] { set(optional, value) }
        }
        let charges = uti["Charges"] ?? .byte(0)
        set("Charges", charges)
        set("MaxCharges", .byte(UInt8(clamping: charges.integer ?? 0)))
        copy("Cost", default: .dword(0))
        copy("AddCost", default: .dword(0))
        copy("Plot", default: .byte(0))
        copy("PropertiesList", default: .list([]))
        for axis in ["X", "Y", "Z"] { set("\(axis)Position", .float(0)) }
        set("XOrientation", .float(1))
        set("YOrientation", .float(0))
        set("ZOrientation", .float(0))
        set("NonEquippable", .byte(0))
        set("NewItem", .byte(1))
        set("DELETING", .byte(0))
        return fields
    }
}
