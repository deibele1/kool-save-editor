import Aurora
import KotORSave
import SwiftUI

extension GameData {
    func itemName(_ item: GFFStruct) -> String {
        if let name = text(item.locString("LocalizedName")), !name.isEmpty { return name }
        return item.string("Tag", encoding: encoding) ?? "Unknown item"
    }

    func itemIconName(_ item: GFFStruct) -> String? {
        itemIcon(baseItem: item.integer("BaseItem") ?? 0,
                 modelVariation: item.integer("ModelVariation") ?? item.integer("TextureVar") ?? 1)
    }
}

struct EquipmentView: View {
    let document: SaveDocument
    let character: CharacterID

    @State private var picking: EquipmentSlot?

    var body: some View {
        let creature = document.save?.creature(character)
        let data = document.gameData
        VStack(alignment: .leading, spacing: 10) {
            List {
                ForEach(EquipmentSlot.slots(for: document.game)) { slot in
                    let item = creature?.equippedItem(slot)
                    HStack(spacing: 10) {
                        GameImage(name: item.flatMap { data?.itemIconName($0) }, assets: data?.assets, placeholder: "square.dashed")
                            .frame(width: 34, height: 34)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(slot.title).font(.caption).foregroundStyle(.secondary)
                            if let item {
                                Text(data?.itemName(item) ?? item.string("Tag") ?? "Item")
                                Text(item.string("Tag") ?? "").font(.caption2).foregroundStyle(.tertiary)
                            } else {
                                Text("Empty").foregroundStyle(.tertiary)
                            }
                        }
                        Spacer()
                        Button(item == nil ? "Equip…" : "Change…") { picking = slot }
                            .disabled(!(data?.isAvailable ?? false))
                        Button("Unequip") {
                            document.edit("Unequip \(slot.title)") { $0.unequip(slot, from: character) }
                        }
                        .disabled(item == nil)
                        .help("Move the item to the party inventory")
                    }
                    .padding(.vertical, 2)
                }
            }
            Text("Replacing an item keeps its object ID, as KSE did; an empty slot gets a new ID from the module. Unequipped items go to the party inventory.")
                .font(.callout)
                .foregroundStyle(.secondary)
            GameDataNotice(gameData: data)
        }
        .padding(.top, 8)
        .sheet(item: $picking) { slot in
            if let data {
                ItemPickerSheet(mode: .equip(slot), gameData: data, owned: []) { templates, _ in
                    guard let first = templates.first, let template = data.itemTemplate(first.resRef) else { return }
                    document.edit("Equip \(first.name.isEmpty ? first.resRef : first.name)") {
                        $0.equip(template, slot: slot, on: character)
                    }
                }
            }
        }
    }
}

/// Browses the game's item blueprints (templates BIF and override folder).
struct ItemPickerSheet: View {
    enum Mode {
        case equip(EquipmentSlot)
        case inventory
    }

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case weapons = "Weapons"
        case wearable = "Wearable"
        case other = "Other"
        case override = "Override"
        var id: Self { self }
    }

    let mode: Mode
    let gameData: GameData
    let owned: Set<String>
    let add: ([ItemTemplate], Int) -> Void

    @State private var templates: [ItemTemplate] = []
    @State private var loading = true
    @State private var search = ""
    @State private var filter = Filter.all
    @State private var selection = Set<String>()
    @State private var quantity = 1
    @State private var description: String?
    @State private var sortOrder = [KeyPathComparator(\ItemTemplate.name)]
    @Environment(\.dismiss) private var dismiss

    private var isEquipping: Bool { if case .equip = mode { true } else { false } }

    private var visible: [ItemTemplate] {
        templates.filter { template in
            let slots = gameData.baseItems[template.baseItem]?.equipableSlots ?? 0
            if case .equip(let slot) = mode, slots & slot.equipBit == 0 { return false }
            switch filter {
            case .all: break
            case .weapons: if slots & 0x30 == 0 { return false }
            case .wearable: if slots == 0 || slots & 0x30 != 0 { return false }
            case .other: if slots != 0 { return false }
            case .override: if !template.isOverride { return false }
            }
            guard !search.isEmpty else { return true }
            return template.name.localizedCaseInsensitiveContains(search) || template.tag.localizedCaseInsensitiveContains(search)
                || template.resRef.localizedCaseInsensitiveContains(search)
        }
        .sorted(using: sortOrder)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.headline)
                HStack {
                    SearchField(text: $search, prompt: "Search names, tags and resrefs")
                    if !isEquipping {
                        Picker("Show", selection: $filter) {
                            ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .fixedSize()
                    }
                }
            }
            .padding()

            Table(visible, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Name", value: \.name) { template in
                    HStack(spacing: 6) {
                        GameImage(name: gameData.itemIcon(baseItem: template.baseItem, modelVariation: template.modelVariation),
                                  assets: gameData.assets, placeholder: "shippingbox")
                            .frame(width: 22, height: 22)
                        Text(template.name.isEmpty ? template.resRef : template.name)
                            .foregroundStyle(owned.contains(template.tag.lowercased()) ? Color.accentColor : .primary)
                        if template.isOverride {
                            Text("Override").font(.caption2).padding(.horizontal, 4).background(.orange.opacity(0.2), in: Capsule())
                        }
                    }
                }
                TableColumn("Type") { template in
                    Text(gameData.baseItemName(template.baseItem)).foregroundStyle(.secondary)
                }
                .width(min: 90, ideal: 130)
                TableColumn("Tag", value: \.tag) { template in
                    Text(template.tag).font(.callout.monospaced()).foregroundStyle(.secondary)
                }
                .width(min: 90, ideal: 150)
                TableColumn("ResRef", value: \.resRef) { template in
                    Text(template.resRef).font(.callout.monospaced()).foregroundStyle(.secondary)
                }
                .width(min: 90, ideal: 140)
            }
            .contextMenu(forSelectionType: String.self) { _ in } primaryAction: { ids in
                confirm(ids)
                dismiss()
            }
            .overlay {
                if loading { ProgressView("Reading item blueprints…") }
                else if visible.isEmpty { ContentUnavailableView.search }
            }
            .onChange(of: selection) { _, ids in
                description = ids.count == 1 ? describe(ids.first!) : nil
            }

            if let description, !description.isEmpty {
                ScrollView {
                    Text(description).font(.callout).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }
                .frame(height: 64)
                .padding(.horizontal)
                .padding(.top, 8)
            }

            Divider().padding(.top, 8)
            SheetFooter(confirmTitle: isEquipping ? "Equip" : (selection.count > 1 ? "Add \(selection.count) Items" : "Add"),
                        confirmDisabled: selection.isEmpty || (isEquipping && selection.count != 1)) {
                confirm(selection)
            } leading: {
                if !isEquipping {
                    Stepper("Quantity: \(quantity)", value: $quantity, in: 1 ... 999)
                        .fixedSize()
                    Text("Items you already have are highlighted.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 760, height: 640)
        .task {
            templates = await gameData.assets.itemTemplates()
            loading = false
        }
    }

    private var title: String {
        switch mode {
        case .equip(let slot): "Equip \(slot.title)"
        case .inventory: "Add Items"
        }
    }

    private func confirm(_ ids: Set<String>) {
        let chosen = templates.filter { ids.contains($0.resRef) }
        guard !chosen.isEmpty else { return }
        add(chosen, quantity)
    }

    private func describe(_ resRef: String) -> String? {
        guard let root = gameData.itemTemplate(resRef)?.root else { return nil }
        return gameData.text(root.locString("DescIdentified")) ?? gameData.text(root.locString("Description"))
    }
}

struct InventoryView: View {
    @Environment(AppModel.self) private var model
    let document: SaveDocument

    @State private var selection = Set<Int>()
    @State private var adding = false
    @State private var search = ""
    @State private var confirmPaste = false
    @State private var sortOrder = [KeyPathComparator(\InventoryRow.name)]

    nonisolated struct InventoryRow: Identifiable, Sendable {
        var item: InventoryItem
        var name: String
        var type: String
        var id: Int { item.index }
        var tag: String { item.tag }
        var quantity: Int { item.stackSize }
    }

    var body: some View {
        let data = document.gameData
        let rows = (document.save?.inventoryItems ?? []).map { item in
            InventoryRow(item: item, name: data?.text(item.name) ?? item.tag, type: data?.baseItemName(item.baseItem) ?? "\(item.baseItem)")
        }
        let visible = rows.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.tag.localizedCaseInsensitiveContains(search) }
            .sorted(using: sortOrder)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SearchField(text: $search, prompt: "Filter inventory")
                    .frame(maxWidth: 280)
                Spacer()
                Text("\(rows.count) items").foregroundStyle(.secondary)
            }
            Table(visible, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Name", value: \.name) { row in
                    HStack(spacing: 6) {
                        GameImage(name: data?.itemIcon(baseItem: row.item.baseItem, modelVariation: row.item.modelVariation),
                                  assets: data?.assets, placeholder: "shippingbox")
                            .frame(width: 22, height: 22)
                        Text(row.name)
                    }
                }
                TableColumn("Type", value: \.type) { row in
                    Text(row.type).foregroundStyle(.secondary)
                }
                .width(min: 80, ideal: 120)
                TableColumn("Tag", value: \.tag) { row in
                    Text(row.tag).font(.callout.monospaced()).foregroundStyle(.secondary)
                }
                .width(min: 90, ideal: 160)
                TableColumn("Quantity", value: \.quantity) { row in
                    Stepper(value: quantityBinding(row.item), in: 1 ... 9999) {
                        TextField("Quantity", value: quantityBinding(row.item), format: .number)
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 56)
                    }
                }
                .width(min: 110, ideal: 120)
            }
            .contextMenu(forSelectionType: Int.self) { ids in
                Button(ids.count > 1 ? "Remove \(ids.count) Items" : "Remove Item") { remove(ids) }
            }
            .onDeleteCommand { remove(selection) }
            HStack {
                Button("Add Items…") { adding = true }
                    .disabled(!(data?.isAvailable ?? false))
                Button("Remove") { remove(selection) }
                    .disabled(selection.isEmpty)
                Spacer()
                Button("Copy Inventory") { model.copyInventory(from: document) }
                Button("Paste Inventory…") { confirmPaste = true }
                    .disabled(!model.canPasteInventory(into: document))
            }
            GameDataNotice(gameData: data)
        }
        .padding(20)
        .sheet(isPresented: $adding) {
            if let data {
                ItemPickerSheet(mode: .inventory, gameData: data, owned: Set(rows.map { $0.tag.lowercased() })) { templates, count in
                    let documents = templates.compactMap { template in data.itemTemplate(template.resRef) }
                    document.edit(documents.count == 1 ? "Add Item" : "Add Items") { save in
                        for template in documents {
                            let limit = data.baseItems[template.root.integer("BaseItem") ?? -1]?.stacking ?? 1
                            save.addInventoryItem(template, count: count, stackLimit: limit)
                        }
                    }
                }
            }
        }
        .confirmationDialog("Replace this inventory?", isPresented: $confirmPaste) {
            Button("Replace Inventory", role: .destructive) { model.pasteInventory(into: document) }
        } message: {
            Text("The inventory of “\(model.inventoryClipboard?.sourceName ?? "")” (\(model.inventoryClipboard?.items.count ?? 0) items) replaces this save’s inventory. You can undo this or revert before saving.")
        }
    }

    private func quantityBinding(_ item: InventoryItem) -> Binding<Int> {
        document.binding("Change Quantity",
                         { $0.inventoryItems.first { $0.index == item.index }?.stackSize ?? item.stackSize },
                         { save, value in save.setStackSize(item.index, max(1, value)) })
    }

    private func remove(_ ids: Set<Int>) {
        guard !ids.isEmpty else { return }
        document.edit(ids.count == 1 ? "Remove Item" : "Remove Items") { $0.removeInventoryItems(IndexSet(ids)) }
        selection = []
    }
}
