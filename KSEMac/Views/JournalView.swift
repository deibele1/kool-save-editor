import KotORSave
import SwiftUI

struct JournalView: View {
    let document: SaveDocument

    @State private var selection: String?
    @State private var adding = false

    var body: some View {
        let data = document.gameData
        let entries = document.save?.journalEntries ?? []
        let tokens = document.textTokens
        HSplitView {
            VStack(alignment: .leading, spacing: 10) {
                List(entries, selection: $selection) { entry in
                    let quest = data?.quests[entry.id]
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tokens.apply(quest?.name ?? entry.plotID))
                        Text(tokens.apply(stateTitle(entry, quest))).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .tag(entry.id)
                }
                .onDeleteCommand { removeSelected() }
                .overlay { if entries.isEmpty { ContentUnavailableView("No Quests", systemImage: "book.closed") } }
                HStack {
                    Button("Add Quests…") { adding = true }
                        .disabled(data?.quests.isEmpty ?? true)
                    Button("Remove") { removeSelected() }
                        .disabled(selection == nil)
                    Spacer()
                }
                GameDataNotice(gameData: data, message: "Quest names, journal text and the list of quests to add come from global.jrl and dialog.tlk.")
            }
            .padding(20)
            .frame(minWidth: 300)

            Group {
                if let entry = entries.first(where: { $0.id == selection }) {
                    QuestDetail(document: document, entry: entry, quest: data?.quests[entry.id])
                } else {
                    ContentUnavailableView("No Quest Selected", systemImage: "text.book.closed")
                }
            }
            .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(isPresented: $adding) {
            QuestPickerSheet(quests: Array((data?.quests ?? [:]).values), known: Set(entries.map(\.id)), tokens: tokens) { quests in
                document.edit(quests.count == 1 ? "Add Quest" : "Add Quests") { save in
                    for quest in quests { save.addQuest(quest.tag, state: quest.entries.first?.id ?? 10) }
                }
            }
        }
    }

    private func stateTitle(_ entry: JournalEntry, _ quest: QuestInfo?) -> String {
        guard let text = quest?.entries.first(where: { $0.id == entry.state })?.text, !text.isEmpty else { return "State \(entry.state)" }
        return "\(entry.state): \(text)"
    }

    private func removeSelected() {
        guard let selection else { return }
        document.edit("Remove Quest") { $0.removeQuests([selection]) }
        self.selection = nil
    }
}

struct QuestDetail: View {
    let document: SaveDocument
    let entry: JournalEntry
    let quest: QuestInfo?

    var body: some View {
        let tokens = document.textTokens
        Form {
            Section {
                LabeledContent("Quest", value: tokens.apply(quest?.name ?? entry.plotID))
                LabeledContent("Plot ID", value: entry.plotID)
                if let quest, !quest.entries.isEmpty {
                    Picker("State", selection: document.binding("Change Quest State",
                                                                { $0.journalEntries.first { $0.id == entry.id }?.state ?? entry.state },
                                                                { $0.setQuestState(entry.plotID, $1) })) {
                        ForEach(stateChoices(quest)) { state in
                            Text(label(state, tokens)).tag(state.id)
                        }
                    }
                } else {
                    NumberField(title: "State", value: document.binding("Change Quest State",
                                                                        { $0.journalEntries.first { $0.id == entry.id }?.state ?? entry.state },
                                                                        { $0.setQuestState(entry.plotID, $1) }),
                                range: Int(Int32.min) ... Int(Int32.max))
                }
            }
            if let text = quest?.entries.first(where: { $0.id == entry.state })?.text, !text.isEmpty {
                Section("Journal Entry") {
                    Text(tokens.apply(text)).textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func stateChoices(_ quest: QuestInfo) -> [QuestInfo.Entry] {
        var choices = quest.entries
        if !choices.contains(where: { $0.id == entry.state }) {
            choices.append(.init(id: entry.state, text: "", isEnd: false))
        }
        return choices.sorted { $0.id < $1.id }
    }

    private func label(_ state: QuestInfo.Entry, _ tokens: TextTokens) -> String {
        let full = tokens.apply(state.text)
        let text = full.count > 70 ? full.prefix(67) + "…" : full
        return "\(state.id)\(state.isEnd ? " (end)" : "")" + (text.isEmpty ? "" : " — \(text)")
    }
}

struct QuestPickerSheet: View {
    let quests: [QuestInfo]
    let known: Set<String>
    let tokens: TextTokens
    let add: ([QuestInfo]) -> Void

    @State private var selection = Set<String>()
    @State private var search = ""

    private var visible: [QuestInfo] {
        quests.filter { SearchText.matches(search, tokens.apply($0.name), $0.tag) }
            .sorted { tokens.apply($0.name).localizedLowercase < tokens.apply($1.name).localizedLowercase }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Add Quests").font(.headline)
                SearchField(text: $search)
            }
            .padding()
            List(visible, selection: $selection) { quest in
                HStack {
                    VStack(alignment: .leading) {
                        Text(tokens.apply(quest.name))
                        Text(quest.tag).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if known.contains(quest.tag) { Text("In journal").font(.caption).foregroundStyle(.secondary) }
                }
                .tag(quest.tag)
            }
            Divider()
            let new = quests.filter { selection.contains($0.tag) && !known.contains($0.tag) }
            SheetFooter(confirmTitle: new.count > 1 ? "Add \(new.count)" : "Add", confirmDisabled: new.isEmpty) { add(new) }
        }
        .frame(width: 480, height: 560)
    }
}
