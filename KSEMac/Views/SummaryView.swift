import AppKit
import KotORSave
import SwiftUI

struct SummaryView: View {
    @Environment(AppModel.self) private var model
    let document: SaveDocument

    var body: some View {
        if let save = document.save {
            Form {
                Section {
                    HStack(alignment: .top, spacing: 18) {
                        Group {
                            if let image = model.thumbnails[document.id] {
                                Image(nsImage: image).resizable()
                            } else {
                                Rectangle().fill(.quaternary)
                            }
                        }
                        .aspectRatio(4 / 3, contentMode: .fit)
                        .frame(width: 240)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))

                        VStack(alignment: .leading, spacing: 6) {
                            Text(save.saveName.isEmpty ? document.summary.folderName : save.saveName).font(.title2.bold())
                            Text(save.areaName).font(.title3).foregroundStyle(.secondary)
                            Text(document.name(of: .player)).foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            Text("Modified \(document.summary.modified.formatted(date: .abbreviated, time: .shortened))")
                                .font(.callout)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("Savegame") {
                    CommitTextField(title: "Name", value: save.saveName, encoding: save.encoding) { name in
                        document.edit("Rename Save") { $0.saveName = name }
                    }
                    LabeledContent("Area", value: save.areaName)
                    LabeledContent("Module", value: save.moduleResRef)
                    TimePlayedField(seconds: document.binding("Change Time Played", { $0.timePlayed }, { $0.timePlayed = $1 }))
                    Toggle("Cheats used", isOn: document.binding("Change Cheat Flag", { $0.cheatUsed }, { $0.cheatUsed = $1 }))
                }

                Section("Location") {
                    LabeledContent("Game", value: "\(document.game.title) (\(document.location.sourceTitle))")
                    LabeledContent("Folder") {
                        HStack {
                            Text(document.summary.folder.path).lineLimit(1).truncationMode(.head).textSelection(.enabled)
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([document.summary.folder]) }
                        }
                    }
                    if !save.fileNames.signatures.isEmpty {
                        LabeledContent("Xbox signatures", value: "Regenerated on save")
                    }
                }

                if document.gameData?.isAvailable != true {
                    Section { GameDataNotice(gameData: document.gameData) }
                }
            }
            .formStyle(.grouped)
        }
    }
}

struct TimePlayedField: View {
    @Binding var seconds: Int

    var body: some View {
        LabeledContent("Time played") {
            HStack(spacing: 4) {
                part(\.hours, suffix: "h", range: 0 ... 99_999)
                part(\.minutes, suffix: "m", range: 0 ... 59)
                part(\.seconds, suffix: "s", range: 0 ... 59)
            }
        }
    }

    private struct Parts {
        var hours: Int
        var minutes: Int
        var seconds: Int
    }

    private func part(_ keyPath: WritableKeyPath<Parts, Int>, suffix: String, range: ClosedRange<Int>) -> some View {
        let binding = Binding<Int>(
            get: { Parts(hours: seconds / 3600, minutes: seconds % 3600 / 60, seconds: seconds % 60)[keyPath: keyPath] },
            set: { value in
                var parts = Parts(hours: seconds / 3600, minutes: seconds % 3600 / 60, seconds: seconds % 60)
                parts[keyPath: keyPath] = min(max(value, range.lowerBound), range.upperBound)
                seconds = parts.hours * 3600 + parts.minutes * 60 + parts.seconds
            })
        return HStack(spacing: 2) {
            TextField(suffix, value: binding, format: .number.grouping(.never))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(width: suffix == "h" ? 64 : 40)
            Text(suffix).foregroundStyle(.secondary)
        }
    }
}
