import AppKit
import Aurora
import KotORSave
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GamesSettings()
                .tabItem { Label("Games", systemImage: "gamecontroller") }
            SavingSettings()
                .tabItem { Label("Saving", systemImage: "clock.arrow.circlepath") }
            AdvancedSettings()
                .tabItem { Label("Advanced", systemImage: "gearshape.2") }
        }
        .frame(width: 600)
    }
}

struct GamesSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            ForEach(Game.allCases) { game in
                Section(game.title) {
                    let data = model.gameData[game]
                    LabeledContent("Game folder") {
                        VStack(alignment: .trailing, spacing: 4) {
                            Text(model.gameFolder(for: game)?.path ?? "Not found")
                                .lineLimit(2)
                                .truncationMode(.middle)
                                .foregroundStyle(model.gameFolder(for: game) == nil ? .secondary : .primary)
                                .textSelection(.enabled)
                            HStack {
                                if model.preferences.gameFolder(for: game) != nil {
                                    Button("Use Automatic") { model.preferences.setGameFolder(nil, for: game) }
                                }
                                Button("Choose…") { choose(game) }
                            }
                        }
                    }
                    LabeledContent("Status") {
                        if let data, data.isAvailable {
                            Label("Names, icons and item lists available", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else {
                            Label(data?.problem ?? "Looking…", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
            Section {
                Text("The game folder is the one containing chitin.key. For the Mac versions it is inside the app: right-click the game in Finder, choose Show Package Contents, and pick the folder with chitin.key (Contents/Assets or Contents/GameData). Saves can be edited without it, with numbers shown instead of names.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section("Save Folders") {
                ForEach(model.locations) { location in
                    LabeledContent {
                        HStack {
                            Text(location.url.path).lineLimit(1).truncationMode(.head).foregroundStyle(.secondary)
                            if location.source == .custom {
                                Button("Remove") { model.removeCustomFolder(location) }
                            }
                        }
                    } label: {
                        Text("\(location.game.shortTitle) · \(location.sourceTitle)")
                    }
                }
                Button("Add Saves Folder…") { model.chooseCustomFolder() }
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 520)
    }

    private func choose(_ game: Game) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = true
        panel.message = "Choose the \(game.title) folder containing chitin.key, or the game’s app."
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let folder = SaveDiscovery.findGameData(in: url, depth: 4) else {
            model.errorMessage = "No chitin.key was found in “\(url.lastPathComponent)”."
            return
        }
        model.preferences.setGameFolder(folder, for: game)
    }
}

struct SavingSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Stepper("Keep the newest \(model.preferences.versionRetention) versions of each save",
                        value: $model.preferences.versionRetention, in: 1 ... 200)
                LabeledContent("Versions folder") {
                    Button("Show in Finder") {
                        try? FileManager.default.createDirectory(at: model.versionStore.root, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(model.versionStore.root)
                    }
                }
            } footer: {
                Text("Before writing, the save folder is copied to the versions folder. Files are replaced atomically and read back; if anything fails, the save is rolled back to that copy.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct AdvancedSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Toggle("Show all feats and powers when adding", isOn: $model.preferences.showAllAbilities)
                Picker("Text encoding", selection: $model.preferences.encodingID) {
                    Text("Automatic (from dialog.tlk)").tag(String?.none)
                    ForEach(TextEncoding.all) { encoding in
                        Text(encoding.name).tag(Optional(encoding.id))
                    }
                }
            } footer: {
                Text("The games store text in a Windows code page chosen by their language. Override it only if names in a localized game look wrong.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
