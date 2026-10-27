import Aurora
import KotORSave
import SwiftUI

/// A text field that reports its value when editing ends (Return or losing focus), so a
/// rename is one undoable change rather than one per keystroke.
struct CommitTextField: View {
    let title: String
    let value: String
    var prompt: String?
    var encoding: TextEncoding?
    let commit: (String) -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            TextField(title, text: $text, prompt: prompt.map { Text($0) })
                .focused($focused)
                .onSubmit(save)
                .onChange(of: focused) { _, isFocused in if !isFocused { save() } }
                .onChange(of: value, initial: true) { _, newValue in if !focused { text = newValue } }
            if let encoding, !encoding.canEncode(text) {
                Text("Some characters can’t be stored by the game and will be replaced.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func save() {
        if text != value { commit(text) }
    }
}

/// An integer field with a stepper, clamped to `range`.
struct NumberField: View {
    let title: String
    @Binding var value: Int
    var range: ClosedRange<Int> = 0 ... Int(Int32.max)
    var step = 1
    var help: String?

    var body: some View {
        LabeledContent {
            HStack(spacing: 6) {
                TextField(title, value: clamped, format: .number)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 96)
                Stepper(title, value: clamped, in: range, step: step)
                    .labelsHidden()
            }
        } label: {
            Text(title)
        }
        .help(help ?? "")
    }

    private var clamped: Binding<Int> {
        Binding(get: { value }, set: { value = min(max($0, range.lowerBound), range.upperBound) })
    }
}

struct SearchField: View {
    @Binding var text: String
    var prompt = "Search"

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
    }
}

/// Cancel / confirm buttons at the bottom of a sheet.
struct SheetFooter<Leading: View>: View {
    let confirmTitle: String
    var confirmDisabled = false
    let confirm: () -> Void
    @ViewBuilder var leading: Leading
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack {
            leading
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(confirmTitle) {
                confirm()
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(confirmDisabled)
        }
        .padding()
    }
}

extension SheetFooter where Leading == EmptyView {
    init(confirmTitle: String, confirmDisabled: Bool = false, confirm: @escaping () -> Void) {
        self.init(confirmTitle: confirmTitle, confirmDisabled: confirmDisabled, confirm: confirm) { EmptyView() }
    }
}

/// Picks one entry of a game table (appearance, soundset, class…).
struct ChoiceSheet: View {
    struct Choice: Identifiable, Hashable {
        let id: Int
        let title: String
    }

    let title: String
    let choices: [Choice]
    let current: Int
    let choose: (Int) -> Void

    @State private var selection: Int?
    @State private var search = ""
    @Environment(\.dismiss) private var dismiss

    private var filtered: [Choice] {
        guard !search.isEmpty else { return choices }
        return choices.filter { $0.title.localizedCaseInsensitiveContains(search) || String($0.id) == search }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.headline)
                SearchField(text: $search)
            }
            .padding()
            List(filtered, selection: $selection) { choice in
                HStack {
                    Text(choice.title)
                    Spacer()
                    Text("\(choice.id)").foregroundStyle(.secondary).monospacedDigit()
                }
                .tag(choice.id)
            }
            .contextMenu(forSelectionType: Int.self) { _ in } primaryAction: { ids in
                if let id = ids.first { choose(id); dismiss() }
            }
            Divider()
            SheetFooter(confirmTitle: "Choose", confirmDisabled: selection == nil) {
                if let selection { choose(selection) }
            }
        }
        .frame(width: 460, height: 560)
        .onAppear { selection = current }
    }
}

extension ChoiceSheet.Choice {
    static func from(_ table: [Int: String], including current: Int, missing: (Int) -> String) -> [ChoiceSheet.Choice] {
        var entries = table.map { ChoiceSheet.Choice(id: $0.key, title: $0.value) }
        if table[current] == nil { entries.append(.init(id: current, title: missing(current))) }
        return entries.sorted { ($0.title.localizedLowercase, $0.id) < ($1.title.localizedLowercase, $1.id) }
    }
}

/// A row showing a value with a button that opens a picker.
struct PickerRow<Accessory: View>: View {
    let title: String
    let value: String
    let action: () -> Void
    var disabled = false
    @ViewBuilder var accessory: Accessory

    var body: some View {
        LabeledContent(title) {
            HStack {
                accessory
                Text(value).lineLimit(1).truncationMode(.middle)
                Button("Change…", action: action).disabled(disabled)
            }
        }
    }
}

extension PickerRow where Accessory == EmptyView {
    init(title: String, value: String, disabled: Bool = false, action: @escaping () -> Void) {
        self.init(title: title, value: value, action: action, disabled: disabled) { EmptyView() }
    }
}

extension Duration {
    var playTime: String { formatted(.units(allowed: [.hours, .minutes], width: .narrow)) }
}

/// Shown where a feature needs the game's own data files.
struct GameDataNotice: View {
    let gameData: GameData?
    var message = "Names and the lists of things to add come from the game’s data files."

    var body: some View {
        if gameData?.isAvailable != true {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                VStack(alignment: .leading, spacing: 4) {
                    Text(gameData?.problem ?? "The game folder has not been located.").font(.callout.weight(.medium))
                    Text(message).font(.callout).foregroundStyle(.secondary)
                    SettingsLink { Text("Locate Game Folder…") }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.yellow.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}
