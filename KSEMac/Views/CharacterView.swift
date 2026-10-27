import Aurora
import KotORSave
import SwiftUI

extension SaveDocument {
    /// A binding to a creature property that edits through `edit`.
    func creatureBinding<Value: Equatable>(_ character: CharacterID, _ action: String,
                                           _ keyPath: WritableKeyPath<Creature, Value>) -> Binding<Value> {
        binding(action, { $0.creature(character)?[keyPath: keyPath] }, { save, value in
            save.updateCreature(character) { $0[keyPath: keyPath] = value }
        })
    }
}

struct CharacterView: View {
    let document: SaveDocument
    let character: CharacterID

    enum Tab: Hashable {
        case general, abilities, feats, powers, classes, equipment
    }

    @State private var tab = Self.initialTab

    private static var initialTab: Tab {
        #if DEBUG
        switch UserDefaults.standard.string(forKey: "KSEMacTab") {
        case "abilities": .abilities
        case "feats": .feats
        case "powers": .powers
        case "classes": .classes
        case "equipment": .equipment
        default: .general
        }
        #else
        .general
        #endif
    }

    var body: some View {
        if let creature = document.save?.creature(character) {
            VStack(alignment: .leading, spacing: 0) {
                CharacterHeader(document: document, character: character, creature: creature)
                    .padding([.horizontal, .top], 20)
                    .padding(.bottom, 12)
                TabView(selection: $tab) {
                    CharacterGeneralView(document: document, character: character)
                        .tabItem { Text("General") }.tag(Tab.general)
                    AbilitiesView(document: document, character: character)
                        .tabItem { Text("Attributes & Skills") }.tag(Tab.abilities)
                    FeatsView(document: document, character: character)
                        .tabItem { Text("Feats") }.tag(Tab.feats)
                    PowersView(document: document, character: character)
                        .tabItem { Text("Force Powers") }.tag(Tab.powers)
                    ClassesView(document: document, character: character)
                        .tabItem { Text("Classes") }.tag(Tab.classes)
                    EquipmentView(document: document, character: character)
                        .tabItem { Text("Equipment") }.tag(Tab.equipment)
                }
                .padding([.horizontal, .bottom], 20)
            }
        } else {
            ContentUnavailableView("Character Not Found", systemImage: "person.crop.circle.badge.questionmark",
                                   description: Text("This save has no sheet for this character."))
        }
    }
}

struct CharacterHeader: View {
    let document: SaveDocument
    let character: CharacterID
    let creature: Creature

    var body: some View {
        HStack(spacing: 14) {
            GameImage(name: document.gameData?.portraits[creature.portrait], assets: document.gameData?.assets,
                      placeholder: "person.crop.square")
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
            VStack(alignment: .leading, spacing: 3) {
                Text(document.name(of: character)).font(.title2.bold())
                Text(classSummary).foregroundStyle(.secondary)
                if case .npc(let index) = character {
                    Text(companionStatus(index)).font(.caption).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text("Level \(creature.level)").font(.headline)
                Text("\(creature.experience.formatted()) XP").foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }

    private var classSummary: String {
        let parts = creature.classes.map { "\(document.gameData?.className($0.classID) ?? "Class \($0.classID)") \($0.level)" }
        return parts.isEmpty ? "No class" : parts.joined(separator: " / ")
    }

    private func companionStatus(_ index: Int) -> String {
        guard let save = document.save else { return "" }
        var parts = [save.isCompanionAvailable(index) ? "Available" : "Not available"]
        if save.partyMemberIDs.contains(index) { parts.append("In the active party") }
        return parts.joined(separator: " · ")
    }
}

struct CharacterGeneralView: View {
    let document: SaveDocument
    let character: CharacterID

    enum Picker: Identifiable {
        case appearance, portrait, soundset
        var id: Self { self }
    }

    @State private var picker: Picker?

    var body: some View {
        if let save = document.save, let creature = save.creature(character) {
            let data = document.gameData
            Form {
                Section("Identity") {
                    CommitTextField(title: "Name", value: data?.text(creature.firstName) ?? "", encoding: save.encoding) { name in
                        document.edit("Rename Character") { save in
                            if character == .player { save.setPlayerName(name) } else { save.updateCreature(character) { $0.setFirstName(name) } }
                        }
                    }
                    SwiftUI.Picker("Gender", selection: document.creatureBinding(character, "Change Gender", \.gender)) {
                        ForEach(genderChoices(current: creature.gender), id: \.self) { id in
                            Text(data?.genderName(id) ?? "Gender \(id)").tag(id)
                        }
                    }
                    PickerRow(title: "Appearance", value: data?.appearanceName(creature.appearance) ?? "\(creature.appearance)",
                              disabled: data?.appearances.isEmpty ?? true) { picker = .appearance }
                    PickerRow(title: "Portrait", value: data?.portraitName(creature.portrait) ?? "\(creature.portrait)",
                              action: { picker = .portrait }, disabled: data?.portraits.isEmpty ?? true) {
                        GameImage(name: data?.portraits[creature.portrait], assets: data?.assets, placeholder: "person.crop.square")
                            .frame(width: 28, height: 28)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    PickerRow(title: "Soundset", value: data?.soundsetName(creature.soundset) ?? "\(creature.soundset)",
                              disabled: data?.soundsets.isEmpty ?? true) { picker = .soundset }
                }

                Section("Progress") {
                    NumberField(title: "Experience", value: document.creatureBinding(character, "Change Experience", \.experience),
                                step: 1000)
                    LabeledContent("Alignment") {
                        HStack {
                            Text("Dark").font(.caption).foregroundStyle(.secondary)
                            Slider(value: Binding(
                                get: { Double(creature.goodEvil) },
                                set: { value in
                                    let rounded = Int(value.rounded())
                                    guard rounded != document.save?.creature(character)?.goodEvil else { return }
                                    document.edit("Change Alignment") { $0.updateCreature(character) { $0.goodEvil = rounded } }
                                }), in: 0 ... 100)
                                .frame(maxWidth: 260)
                            Text("Light").font(.caption).foregroundStyle(.secondary)
                            Text("\(creature.goodEvil)").monospacedDigit().frame(width: 32, alignment: .trailing)
                        }
                    }
                }

                Section {
                    NumberField(title: "Hit points", value: document.creatureBinding(character, "Change Hit Points", \.hitPoints),
                                range: 0 ... Int(Int16.max), help: "Base hit points. Setting them also heals to this value, as KSE did.")
                    NumberField(title: "Maximum hit points", value: document.creatureBinding(character, "Change Maximum Hit Points", \.maxHitPoints),
                                range: 0 ... Int(Int16.max))
                    NumberField(title: "Force points", value: document.creatureBinding(character, "Change Force Points", \.forcePoints),
                                range: 0 ... Int(Int16.max), help: "Base Force points. Setting them also restores the current Force points.")
                    NumberField(title: "Maximum Force points", value: document.creatureBinding(character, "Change Maximum Force Points", \.maxForcePoints),
                                range: 0 ... Int(Int16.max))
                    Toggle("Can’t drop below 1 hit point", isOn: document.creatureBinding(character, "Change Min 1 HP", \.minimumOneHitPoint))
                } header: {
                    Text("Vitality")
                } footer: {
                    Text("Currently \(creature.currentHitPoints) hit points and \(creature.currentForce) Force points.")
                        .foregroundStyle(.secondary)
                }

                if case .npc(let index) = character, save.supportsInfluence {
                    Section("Influence") {
                        InfluenceRow(document: document, index: index, title: "Influence")
                    }
                }
            }
            .formStyle(.grouped)
            .sheet(item: $picker) { picker in
                sheet(for: picker, creature: creature)
            }
        }
    }

    private func genderChoices(current: Int) -> [Int] {
        var ids = Set(document.gameData?.genders.keys.map { $0 } ?? [0, 1])
        ids.insert(current)
        return ids.sorted()
    }

    @ViewBuilder
    private func sheet(for picker: Picker, creature: Creature) -> some View {
        let data = document.gameData
        switch picker {
        case .appearance:
            ChoiceSheet(title: "Choose Appearance",
                        choices: ChoiceSheet.Choice.from(data?.appearances ?? [:], including: creature.appearance) { "Appearance \($0)" },
                        current: creature.appearance) { id in
                document.edit("Change Appearance") { $0.updateCreature(character) { $0.appearance = id } }
            }
        case .soundset:
            ChoiceSheet(title: "Choose Soundset",
                        choices: ChoiceSheet.Choice.from(data?.soundsets ?? [:], including: creature.soundset) { _ in "None" },
                        current: creature.soundset) { id in
                document.edit("Change Soundset") { $0.updateCreature(character) { $0.soundset = id } }
            }
        case .portrait:
            PortraitSheet(gameData: data, current: creature.portrait) { id in
                document.edit("Change Portrait") { $0.updateCreature(character) { $0.portrait = id } }
            }
        }
    }
}

struct InfluenceRow: View {
    let document: SaveDocument
    let index: Int
    let title: String

    var body: some View {
        let value = document.save?.influence(index)
        LabeledContent {
            HStack {
                Slider(value: Binding(
                    get: { Double(value ?? 50) },
                    set: { newValue in
                        let rounded = Int(newValue.rounded())
                        guard rounded != document.save?.influence(index) else { return }
                        document.edit("Change Influence") { $0.setInfluence(index, rounded) }
                    }), in: 0 ... 100)
                    .frame(maxWidth: 260)
                TextField(title, value: Binding(
                    get: { value ?? 50 },
                    set: { newValue in document.edit("Change Influence") { $0.setInfluence(index, newValue) } }),
                          format: .number)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 56)
            }
        } label: {
            Text(title)
            if value == nil {
                Text("Not recorded yet").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct PortraitSheet: View {
    let gameData: GameData?
    let current: Int
    let choose: (Int) -> Void

    @State private var selection: Int?
    @State private var search = ""
    @Environment(\.dismiss) private var dismiss

    private var portraits: [(id: Int, name: String)] {
        (gameData?.portraits ?? [:]).map { (id: $0.key, name: $0.value) }
            .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
            .sorted { $0.name < $1.name }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Choose Portrait").font(.headline)
                SearchField(text: $search)
            }
            .padding()
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 12)], spacing: 12) {
                    ForEach(portraits, id: \.id) { portrait in
                        VStack(spacing: 4) {
                            GameImage(name: portrait.name, assets: gameData?.assets, placeholder: "person.crop.square")
                                .frame(width: 80, height: 80)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            Text(portrait.name).font(.caption2).lineLimit(1).truncationMode(.middle)
                        }
                        .padding(6)
                        .background(selection == portrait.id ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                        .onTapGesture { selection = portrait.id }
                        .onTapGesture(count: 2) { choose(portrait.id); dismiss() }
                    }
                }
                .padding(.horizontal)
            }
            Divider()
            SheetFooter(confirmTitle: "Choose", confirmDisabled: selection == nil) {
                if let selection { choose(selection) }
            }
        }
        .frame(width: 620, height: 600)
        .onAppear { selection = current }
    }
}

struct AbilitiesView: View {
    let document: SaveDocument
    let character: CharacterID

    var body: some View {
        if let creature = document.save?.creature(character) {
            Form {
                Section("Attributes") {
                    ForEach(Ability.allCases) { ability in
                        let score = creature[ability]
                        NumberField(title: "\(ability.title) (\(modifier(score)))",
                                    value: document.creatureBinding(character, "Change \(ability.title)", \.[ability]),
                                    range: 0 ... 255)
                    }
                }
                Section("Skills") {
                    ForEach(Array(creature.skillRanks.enumerated()), id: \.offset) { skill, rank in
                        NumberField(title: document.gameData?.skillName(skill) ?? "Skill \(skill)",
                                    value: document.binding("Change \(document.gameData?.skillName(skill) ?? "Skill")",
                                                            { $0.creature(character)?.skillRanks[safe: skill] ?? rank },
                                                            { save, value in save.updateCreature(character) { $0.setSkillRank(skill, value) } }),
                                    range: 0 ... 255)
                    }
                }
            }
            .formStyle(.grouped)
        }
    }

    private func modifier(_ score: Int) -> String {
        let value = Int((Double(score - 10) / 2).rounded(.down))
        return value >= 0 ? "+\(value)" : "\(value)"
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
