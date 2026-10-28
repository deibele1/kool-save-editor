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
        case appearance, portrait, voiceSet
        var id: Self { self }
    }

    @State private var picker = Self.initialPicker
    @State private var voice = VoicePlayer()

    private static var initialPicker: Picker? {
        #if DEBUG
        switch UserDefaults.standard.string(forKey: "KSEMacPicker") {
        case "appearance": .appearance
        case "portrait": .portrait
        case "voiceSet": .voiceSet
        default: nil
        }
        #else
        nil
        #endif
    }

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
                              action: { picker = .appearance }, disabled: data?.appearances.isEmpty ?? true) {
                        GameImage(name: data?.appearancePortraits[creature.appearance], assets: data?.assets, placeholder: "person.crop.square")
                            .frame(width: 28, height: 28)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    PickerRow(title: "Portrait", value: data?.portraitName(creature.portrait) ?? "\(creature.portrait)",
                              action: { picker = .portrait }, disabled: data?.portraits.isEmpty ?? true) {
                        GameImage(name: data?.portraits[creature.portrait], assets: data?.assets, placeholder: "person.crop.square")
                            .frame(width: 28, height: 28)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    PickerRow(title: "Voice set", value: data?.soundsetName(creature.soundset) ?? "\(creature.soundset)",
                              action: { picker = .voiceSet }, disabled: data?.soundsets.isEmpty ?? true) {
                        let audible = data?.soundsets[creature.soundset]?.hasSounds == true
                        Button {
                            if let data { voice.play(creature.soundset, from: data) }
                        } label: {
                            Image(systemName: "play.circle")
                        }
                        .buttonStyle(.borderless)
                        .disabled(!audible)
                        .help(audible ? voice.caption(for: creature.soundset) ?? "Play a random line" : "This voice set makes no sound in this game")
                    }
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
            ChoiceSheet(title: "Choose Appearance", choices: appearanceChoices(current: creature.appearance), current: creature.appearance,
                        assets: data?.assets, thumbnailSize: 36, placeholder: "person.crop.square",
                        note: "Faces come from the portraits the game pairs with appearances: player bodies and companions have one.") { id in
                document.edit("Change Appearance") { $0.updateCreature(character) { $0.appearance = id } }
            } accessory: { selection in
                if let selection {
                    HStack(spacing: 12) {
                        GameImage(name: data?.appearancePortraits[selection], assets: data?.assets, placeholder: "person.crop.square")
                            .frame(width: 96, height: 96)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(data?.appearanceName(selection) ?? "Appearance \(selection)").font(.headline)
                            Text(data?.appearancePortraits[selection].map { "Portrait \($0)" } ?? "No portrait shows this appearance")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        case .voiceSet:
            ChoiceSheet(title: "Choose Voice Set", choices: voiceSetChoices(current: creature.soundset), current: creature.soundset,
                        note: voiceSetNote) { id in
                document.edit("Change Voice Set") { $0.updateCreature(character) { $0.soundset = id } }
            } accessory: { selection in
                VoiceSampleRow(gameData: data, soundset: selection)
            }
        case .portrait:
            PortraitSheet(gameData: data, current: creature.portrait) { id in
                document.edit("Change Portrait") { $0.updateCreature(character) { $0.portrait = id } }
            }
        }
    }

    private func appearanceChoices(current: Int) -> [TableChoice] {
        let data = document.gameData
        var labels = data?.appearances ?? [:]
        if labels[current] == nil { labels[current] = "Appearance \(current)" }
        return labels.map { TableChoice(id: $0.key, title: $0.value, image: data?.appearancePortraits[$0.key]) }
            .sorted { ($0.title.localizedLowercase, $0.id) < ($1.title.localizedLowercase, $1.id) }
    }

    /// Player voice sets first, then companions, then everything else with "None" on top.
    private func voiceSetChoices(current: Int) -> [TableChoice] {
        guard let data = document.gameData else { return [] }
        let sections = ["Player", "Party members", "Others"]
        var entries = data.soundsets.values.map { info in
            let section = info.isPlayer ? 0 : info.isPartyMember ? 1 : 2
            return (section: section, silentByDesign: info.resRef == nil && info.isInTable ? 0 : 1,
                    choice: TableChoice(id: info.id, title: info.name, detail: voiceSetDetail(info, data), section: sections[section]))
        }
        if data.soundsets[current] == nil {
            entries.append((2, 0, TableChoice(id: current, title: data.soundsetName(current),
                                              detail: current == 0xFFFF ? nil : "Not in this game’s soundset.2da", section: sections[2])))
        }
        return entries.sorted {
            ($0.section, $0.silentByDesign, $0.choice.title.localizedLowercase, $0.choice.id)
                < ($1.section, $1.silentByDesign, $1.choice.title.localizedLowercase, $1.choice.id)
        }.map(\.choice)
    }

    private func voiceSetDetail(_ info: SoundsetInfo, _ data: GameData) -> String? {
        var parts = info.gender.map { [data.genderName($0)] } ?? []
        if !info.isInTable {
            parts.append("silent (not in this game’s soundset.2da)")
        } else if info.resRef != nil && !info.hasSounds {
            parts.append("silent (sound set file missing)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var voiceSetNote: String? {
        guard character == .player, let data = document.gameData,
              data.soundsets.values.contains(where: { $0.isPlayer && !$0.isInTable }) else { return nil }
        return "In \(data.game.title) the player is silent: its soundset.2da has no player voice sets. Mods that restore the player’s voice add them; until then choosing one makes no sound."
    }
}

/// Plays a random line of a voice set and shows what was said.
struct VoiceSampleRow: View {
    let gameData: GameData?
    let soundset: Int?

    @State private var voice = VoicePlayer()

    var body: some View {
        let info = soundset.flatMap { gameData?.soundsets[$0] }
        HStack(spacing: 10) {
            Button {
                if let soundset, let gameData { voice.play(soundset, from: gameData) }
            } label: {
                Label("Play Sample", systemImage: "play.fill")
            }
            .disabled(info?.hasSounds != true)
            Text(voice.caption(for: soundset) ?? (soundset != nil && info?.hasSounds != true ? "Silent in this game" : ""))
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 0)
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
