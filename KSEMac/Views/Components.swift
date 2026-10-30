import Aurora
import KotORSave
import SwiftUI

/// A text field that reports its value when editing ends (Return, losing focus or the field
/// going away), so a rename is one undoable change rather than one per keystroke. The text
/// goes to the save and character it was typed for, and Save, Revert, Reload and Quit apply
/// it first (`AppModel.commitTyping`).
struct CommitTextField: View {
    @Environment(AppModel.self) private var model
    let title: String
    let value: String
    var prompt: String?
    var encoding: TextEncoding?
    let commit: (String) -> Void

    @State private var text = ""
    @State private var typed: TypedText?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            TextField(title, text: $text, prompt: prompt.map { Text($0) })
                .focused($focused)
                .onSubmit {
                    finish()
                    focused = false
                }
                .onChange(of: focused) { _, isFocused in if !isFocused { finish() } }
                .onChange(of: text) { _, newText in
                    if let typed, !typed.isFinished {
                        typed.text = newText
                    } else if newText != value {
                        let typed = TypedText(original: value, text: newText, apply: commit) { focused = false }
                        self.typed = typed
                        model.beginTyping(typed)
                    }
                }
                // Undo, Revert and Reload show at once, even while the field has focus, unless
                // the user has typed something else since.
                .onChange(of: value, initial: true) { _, newValue in
                    guard typed?.isEdited != true else { return }
                    finish()
                    text = newValue
                }
                .onDisappear(perform: finish)
            if let encoding, !encoding.canEncode(text) {
                Text("Some characters can’t be stored by the game and will be replaced.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    /// Applies what was typed, if it changes anything; otherwise shows the stored value again.
    private func finish() {
        guard let typed else { return }
        self.typed = nil
        let applies = typed.isEdited
        model.finishTyping(typed)
        if !applies { text = value }
    }
}

/// Text typed into a `CommitTextField` and not applied yet. `apply` is the field's action from
/// when typing started, so the text reaches that save and character even if the field shows
/// another one by the time editing ends.
final class TypedText {
    let original: String
    var text: String
    private let apply: (String) -> Void
    private let endEditing: () -> Void
    private(set) var isFinished = false

    init(original: String, text: String, apply: @escaping (String) -> Void, endEditing: @escaping () -> Void) {
        self.original = original
        self.text = text
        self.apply = apply
        self.endEditing = endEditing
    }

    /// Whether finishing changes the save.
    var isEdited: Bool { !isFinished && text != original }

    func finish(endingEditing: Bool) {
        guard !isFinished else { return }
        let edited = isEdited
        isFinished = true
        if edited { apply(text) }
        if endingEditing { endEditing() }
    }
}

/// An integer field with a stepper, clamped to `range`. `warning` is shown under the title,
/// e.g. for a value the save already holds outside the range.
struct NumberField: View {
    let title: String
    @Binding var value: Int
    var range: ClosedRange<Int> = 0 ... Int(Int32.max)
    var step = 1
    var help: String?
    var warning: String?

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
            if let warning {
                Text(warning).font(.caption).foregroundStyle(.orange)
            }
        }
        .help(help ?? "")
    }

    /// The field sets its value again when it gains or loses focus; an unchanged value is
    /// ignored so that alone never clamps (and edits) a value outside the range.
    private var clamped: Binding<Int> {
        Binding(get: { value }, set: { if $0 != value { value = min(max($0, range.lowerBound), range.upperBound) } })
    }
}

/// Forgiving search: every word of the query must appear in one of the fields, ignoring case,
/// accents, apostrophes, other punctuation and a plural "s" ("revans robes" finds
/// "Darth Revan's Robes"). Underscores and hyphens are kept, so tags and resrefs match whole.
enum SearchText {
    static func matches(_ query: String, _ fields: String...) -> Bool {
        let words = normalized(query).split(separator: " ").map { word in
            word.count > 3 && word.hasSuffix("s") ? word.dropLast() : word[...]
        }
        guard !words.isEmpty else { return true }
        let haystack = fields.map(normalized).joined(separator: " ")
        return words.allSatisfy { haystack.contains($0) }
    }

    static func normalized(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        for scalar in text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil).unicodeScalars
        where !"'’‘`´".unicodeScalars.contains(scalar) {
            result.append(CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-" ? scalar : " ")
        }
        return String(result)
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

/// An entry of a game table offered by `ChoiceSheet`.
struct TableChoice: Identifiable, Hashable {
    let id: Int
    let title: String
    var detail: String?
    /// A texture shown as the row's thumbnail.
    var image: String?
    /// Consecutive choices with the same section are listed under it.
    var section: String?
}

/// Picks one entry of a game table (appearance, voice set…). `accessory` shows more about
/// the selected entry under the list.
struct ChoiceSheet<Accessory: View>: View {
    let title: String
    let choices: [TableChoice]
    let current: Int
    var assets: GameAssets?
    /// Shows thumbnails of this size, with `placeholder` for choices without an image.
    var thumbnailSize: CGFloat?
    var placeholder = "photo"
    var note: String?
    let choose: (Int) -> Void
    @ViewBuilder var accessory: (Int?) -> Accessory

    @State private var selection: Int?
    @State private var search = ""
    @Environment(\.dismiss) private var dismiss

    private struct Group: Identifiable {
        let title: String?
        var choices: [TableChoice]
        var id: String { title ?? "" }
    }

    private var groups: [Group] {
        var groups: [Group] = []
        for choice in choices where search.isEmpty || choice.title.localizedCaseInsensitiveContains(search)
            || choice.detail?.localizedCaseInsensitiveContains(search) == true || String(choice.id) == search {
            if let last = groups.indices.last, groups[last].title == choice.section { groups[last].choices.append(choice) }
            else { groups.append(Group(title: choice.section, choices: [choice])) }
        }
        return groups
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.headline)
                SearchField(text: $search)
            }
            .padding()
            ScrollViewReader { proxy in
                List(selection: $selection) {
                    ForEach(groups) { group in
                        if let title = group.title {
                            Section(title) { rows(group.choices) }
                        } else {
                            rows(group.choices)
                        }
                    }
                }
                .contextMenu(forSelectionType: Int.self) { _ in } primaryAction: { ids in
                    if let id = ids.first { choose(id); dismiss() }
                }
                .onAppear {
                    selection = current
                    Task { proxy.scrollTo(current, anchor: .center) }
                }
            }
            if let note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding([.horizontal, .top])
            }
            accessory(selection)
                .padding(.horizontal)
                .padding(.top, 10)
            Divider().padding(.top, 10)
            SheetFooter(confirmTitle: "Choose", confirmDisabled: selection == nil) {
                if let selection { choose(selection) }
            }
        }
        .frame(width: 500, height: 620)
    }

    private func rows(_ choices: [TableChoice]) -> some View {
        ForEach(choices) { choice in
            HStack(spacing: 10) {
                if let thumbnailSize {
                    GameImage(name: choice.image, assets: assets, placeholder: placeholder)
                        .frame(width: thumbnailSize, height: thumbnailSize)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(choice.title)
                    if let detail = choice.detail {
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text("\(choice.id)").foregroundStyle(.secondary).monospacedDigit()
            }
            .tag(choice.id)
        }
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

/// Shown above a save while its game runs; saving waits until the game quits.
struct GameRunningNotice: View {
    let game: Game

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(game.title) is running.").font(.callout.weight(.medium))
                Text(GameRunningError.advice).font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.yellow.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}
