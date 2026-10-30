import KotORSave
import SwiftUI

struct GlobalsView: View {
    let document: SaveDocument

    @State private var kind = GlobalVariable.Kind.boolean
    @State private var search = ""
    @State private var sortOrder = [KeyPathComparator(\GlobalVariable.name)]

    var body: some View {
        let all = document.save?.globalVariables ?? []
        let visible = all.filter { $0.kind == kind && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) }
            .sorted(using: sortOrder)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Kind", selection: $kind) {
                    Text("Booleans").tag(GlobalVariable.Kind.boolean)
                    Text("Numbers").tag(GlobalVariable.Kind.number)
                    Text("Strings").tag(GlobalVariable.Kind.string)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                SearchField(text: $search, prompt: "Filter by name")
                    .frame(maxWidth: 280)
                Spacer()
                Text("\(visible.count) of \(all.filter { $0.kind == kind }.count)").foregroundStyle(.secondary)
            }
            Table(visible, sortOrder: $sortOrder) {
                TableColumn("Name", value: \.name) { variable in
                    Text(variable.name).font(.body.monospaced())
                }
                TableColumn("Value") { variable in
                    value(for: variable)
                }
                .width(min: 140, ideal: 200)
            }
            Text("Global variables drive quest progress and story choices. Change them only if you know what a variable does; the previous version is always kept."
                 + (kind == .number ? " Numbers go from −128 to 127, as the games’ scripts read them." : ""))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .overlay { if document.save?.globals == nil { ContentUnavailableView("No GLOBALVARS.res", systemImage: "globe") } }
    }

    @ViewBuilder
    private func value(for variable: GlobalVariable) -> some View {
        switch variable.kind {
        case .boolean:
            Toggle("", isOn: document.binding("Change \(variable.name)",
                                              { $0.globalBoolean(variable.index) },
                                              { $0.setGlobalBoolean(variable.index, $1) }))
                .labelsHidden()
        case .number:
            Stepper(value: numberBinding(variable), in: SaveGame.globalNumberRange) {
                TextField("Value", value: numberBinding(variable), format: .number)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 56)
            }
            .help("−128 to 127, as the game’s scripts see it")
        case .string:
            CommitTextField(title: "Value", value: variable.text) { text in
                document.edit("Change \(variable.name)") { $0.setGlobalString(variable.index, text) }
            }
            .labelsHidden()
        }
    }

    /// Clamps before the document's binding compares values, so typing a number past the range
    /// that clamps to the current value records no edit.
    private func numberBinding(_ variable: GlobalVariable) -> Binding<Int> {
        let range = SaveGame.globalNumberRange
        let binding = document.binding("Change \(variable.name)",
                                       { $0.globalNumber(variable.index) },
                                       { $0.setGlobalNumber(variable.index, $1) })
        return Binding(get: { binding.wrappedValue }, set: { binding.wrappedValue = min(max($0, range.lowerBound), range.upperBound) })
    }
}
