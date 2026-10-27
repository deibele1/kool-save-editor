import Aurora
import KotORSave
import SwiftUI

/// A feat or power row: icon, name and table label.
struct AbilityRow: View {
    let info: AbilityInfo?
    let id: Int
    let fallback: String
    let assets: GameAssets?

    var body: some View {
        HStack(spacing: 8) {
            GameImage(name: info?.icon, assets: assets, placeholder: "seal")
                .frame(width: 26, height: 26)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 1) {
                Text(info?.name ?? fallback)
                Text(info?.label ?? "#\(id)").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct FeatsView: View {
    @Environment(AppModel.self) private var model
    let document: SaveDocument
    let character: CharacterID

    @State private var selection = Set<Int>()
    @State private var adding = false

    var body: some View {
        let feats = document.save?.creature(character)?.feats ?? []
        let data = document.gameData
        VStack(alignment: .leading, spacing: 10) {
            List(feats.sorted { (data?.featName($0) ?? "") < (data?.featName($1) ?? "") }, id: \.self, selection: $selection) { id in
                AbilityRow(info: data?.feats[id], id: id, fallback: "Feat \(id)", assets: data?.assets)
            }
            .onDeleteCommand(perform: remove)
            .overlay { if feats.isEmpty { ContentUnavailableView("No Feats", systemImage: "seal") } }
            HStack {
                Button("Add Feats…") { adding = true }
                    .disabled(data?.feats.isEmpty ?? true)
                Button("Remove", action: remove)
                    .disabled(selection.isEmpty)
                Spacer()
                Text("\(feats.count) feats").foregroundStyle(.secondary)
            }
            GameDataNotice(gameData: data)
        }
        .padding(.top, 8)
        .sheet(isPresented: $adding) {
            AbilityPickerSheet(title: "Add Feats", abilities: data?.feats ?? [:], owned: Set(feats), assets: data?.assets,
                               showAll: model.preferences.showAllAbilities) { ids in
                document.edit(ids.count == 1 ? "Add Feat" : "Add Feats") { $0.updateCreature(character) { $0.addFeats(ids) } }
            }
        }
    }

    private func remove() {
        guard !selection.isEmpty else { return }
        let ids = selection
        document.edit(ids.count == 1 ? "Remove Feat" : "Remove Feats") { $0.updateCreature(character) { $0.removeFeats(ids) } }
        selection = []
    }
}

struct PowersView: View {
    @Environment(AppModel.self) private var model
    let document: SaveDocument
    let character: CharacterID

    @State private var classIndex: Int?
    @State private var selection = Set<Int>()
    @State private var adding = false

    var body: some View {
        let classes = document.save?.creature(character)?.classes ?? []
        let casters = classes.filter { $0.powers != nil }
        let data = document.gameData
        VStack(alignment: .leading, spacing: 10) {
            if casters.isEmpty {
                ContentUnavailableView {
                    Label("No Force-Using Class", systemImage: "sparkles")
                } description: {
                    Text("Force powers belong to a class. Change or add a Jedi class on the Classes tab, or give an existing class a power list.")
                } actions: {
                    ForEach(classes) { entry in
                        Button("Give \(data?.className(entry.classID) ?? "Class \(entry.classID)") Force Powers") {
                            document.edit("Enable Force Powers") { $0.updateCreature(character) { $0.enablePowers(classIndex: entry.index) } }
                        }
                    }
                }
            } else {
                let current = casters.first { $0.index == classIndex } ?? casters[0]
                if casters.count > 1 {
                    Picker("Class", selection: Binding(get: { current.index }, set: { classIndex = $0; selection = [] })) {
                        ForEach(casters) { Text(data?.className($0.classID) ?? "Class \($0.classID)").tag($0.index) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                let powers = current.powers ?? []
                List(powers.sorted { (data?.powerName($0) ?? "") < (data?.powerName($1) ?? "") }, id: \.self, selection: $selection) { id in
                    AbilityRow(info: data?.powers[id], id: id, fallback: "Power \(id)", assets: data?.assets)
                }
                .onDeleteCommand { remove(from: current.index) }
                .overlay { if powers.isEmpty { ContentUnavailableView("No Powers", systemImage: "sparkles") } }
                HStack {
                    Button("Add Powers…") { adding = true }
                        .disabled(data?.powers.isEmpty ?? true)
                    Button("Remove") { remove(from: current.index) }
                        .disabled(selection.isEmpty)
                    Spacer()
                    Text("\(powers.count) powers").foregroundStyle(.secondary)
                }
                .sheet(isPresented: $adding) {
                    AbilityPickerSheet(title: "Add Force Powers", abilities: data?.powers ?? [:], owned: Set(powers), assets: data?.assets,
                                       showAll: model.preferences.showAllAbilities) { ids in
                        document.edit(ids.count == 1 ? "Add Power" : "Add Powers") {
                            $0.updateCreature(character) { $0.addPowers(ids, classIndex: current.index) }
                        }
                    }
                }
            }
            GameDataNotice(gameData: data)
        }
        .padding(.top, 8)
    }

    private func remove(from index: Int) {
        guard !selection.isEmpty else { return }
        let ids = selection
        document.edit(ids.count == 1 ? "Remove Power" : "Remove Powers") {
            $0.updateCreature(character) { $0.removePowers(ids, classIndex: index) }
        }
        selection = []
    }
}

/// Picks feats or powers to add. KSE's short list hides placeholder rows; "Show all" lists
/// every row of the table.
struct AbilityPickerSheet: View {
    let title: String
    let abilities: [Int: AbilityInfo]
    let owned: Set<Int>
    let assets: GameAssets?
    @State var showAll: Bool
    let add: ([Int]) -> Void

    @State private var selection = Set<Int>()
    @State private var search = ""
    @State private var focused: AbilityInfo?

    private var visible: [AbilityInfo] {
        abilities.values
            .filter { showAll || $0.isCommon }
            .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.label.localizedCaseInsensitiveContains(search) }
            .sorted { ($0.name.localizedLowercase, $0.id) < ($1.name.localizedLowercase, $1.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.headline)
                HStack {
                    SearchField(text: $search)
                    Toggle("Show all", isOn: $showAll)
                        .help("Include rows KSE hides: unused placeholders and non-Force abilities")
                }
            }
            .padding()
            List(visible, selection: $selection) { info in
                HStack {
                    AbilityRow(info: info, id: info.id, fallback: info.label, assets: assets)
                    Spacer()
                    if owned.contains(info.id) {
                        Text("Known").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .tag(info.id)
            }
            .onChange(of: selection) { _, ids in focused = ids.count == 1 ? abilities[ids.first!] : nil }
            if let focused {
                HStack(spacing: 10) {
                    GameImage(name: focused.icon, assets: assets, placeholder: "seal")
                        .frame(width: 48, height: 48)
                    VStack(alignment: .leading) {
                        Text(focused.name).font(.headline)
                        Text("\(focused.label) · row \(focused.id)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal)
                .padding(.top, 8)
            }
            Divider().padding(.top, 8)
            let newIDs = selection.subtracting(owned).sorted()
            SheetFooter(confirmTitle: newIDs.count > 1 ? "Add \(newIDs.count)" : "Add", confirmDisabled: newIDs.isEmpty) {
                add(newIDs)
            }
        }
        .frame(width: 520, height: 620)
    }
}

struct ClassesView: View {
    let document: SaveDocument
    let character: CharacterID

    @State private var selection: Int?

    var body: some View {
        let classes = document.save?.creature(character)?.classes ?? []
        let data = document.gameData
        let available = (data?.classes.values.map { $0 } ?? []).sorted { $0.name < $1.name }
        VStack(alignment: .leading, spacing: 10) {
            Table(classes, selection: $selection) {
                TableColumn("Class") { entry in
                    Text(data?.className(entry.classID) ?? "Class \(entry.classID)")
                }
                TableColumn("Level") { entry in
                    Stepper(value: document.binding("Change Class Level",
                                                    { $0.creature(character)?.classes[safe: entry.index]?.level ?? entry.level },
                                                    { save, level in save.updateCreature(character) { $0.setClassLevel(entry.index, level) } }),
                            in: 1 ... 50) {
                        Text("\(entry.level)").monospacedDigit()
                    }
                }
                .width(min: 90, ideal: 110)
                TableColumn("Force Powers") { entry in
                    Text(entry.powers.map { "\($0.count)" } ?? "—").foregroundStyle(entry.powers == nil ? .secondary : .primary)
                }
                .width(min: 90, ideal: 110)
            }
            HStack {
                Menu("Add Class") {
                    ForEach(available) { info in
                        Button(info.name) {
                            document.edit("Add Class") { $0.updateCreature(character) { $0.addClass(info.id, isSpellcaster: info.isSpellcaster) } }
                        }
                    }
                }
                .fixedSize()
                .disabled(available.isEmpty)
                Menu("Change Class") {
                    ForEach(available) { info in
                        Button(info.name) {
                            guard let index = selection else { return }
                            document.edit("Change Class") {
                                $0.updateCreature(character) { $0.changeClass(index, to: info.id, isSpellcaster: info.isSpellcaster) }
                            }
                        }
                    }
                }
                .fixedSize()
                .disabled(selection == nil || available.isEmpty)
                Button("Remove Class") {
                    guard let index = selection else { return }
                    document.edit("Remove Class") { $0.updateCreature(character) { $0.removeClass(index) } }
                    selection = nil
                }
                .disabled(selection == nil || classes.count <= 1)
                Spacer()
            }
            Text("KotOR characters normally have at most two classes. Changing to a Force-using class adds an empty power list; changing away from one removes its powers.")
                .font(.callout)
                .foregroundStyle(.secondary)
            GameDataNotice(gameData: data)
        }
        .padding(.top, 8)
    }
}
