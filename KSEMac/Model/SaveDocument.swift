import AppKit
import Aurora
import KotORSave
import Observation
import SwiftUI

enum SaveSection: Hashable {
    case summary
    case character(CharacterID)
    case party
    case inventory
    case journal
    case globals
    case versions
}

/// One loaded save, its pending edits and its version history.
@Observable
final class SaveDocument: Identifiable {
    enum State {
        case loading
        case ready
        case failed(String)
    }

    let id: String
    let location: SaveLocation
    var summary: SaveSummary
    var gameData: GameData?
    var section: SaveSection? = .summary

    private(set) var state: State = .loading
    private(set) var baseline: SaveGame?
    private(set) var save: SaveGame?
    private(set) var changeCount = 0
    private(set) var changeNames: [String] = []
    private(set) var isSaving = false
    private(set) var versions: [SaveVersion] = []
    private(set) var currentState: CurrentSaveState?
    var externalChanges: [String]?
    var errorMessage: String?

    @ObservationIgnored weak var undoManager: UndoManager?

    init(summary: SaveSummary, location: SaveLocation) {
        id = summary.id
        self.summary = summary
        self.location = location
    }

    var isDirty: Bool { changeCount != 0 }
    var isReady: Bool { if case .ready = state { true } else { false } }
    var game: Game { save?.game ?? location.game }

    /// A short description of the pending edits, used to label the version saved before writing.
    var changeSummary: String {
        var seen = Set<String>()
        let names = changeNames.filter { seen.insert($0).inserted }
        let text = names.prefix(6).joined(separator: ", ") + (names.count > 6 ? ", …" : "")
        return text.isEmpty ? "Edit" : text
    }

    // MARK: Loading

    func load(using model: AppModel) {
        state = .loading
        let folder = summary.folder, game = location.game
        let gameDataTask = model.loadGameData(game)
        Task {
            let data = await gameDataTask.value
            gameData = data
            let result = await Task.detached(priority: .userInitiated) {
                Result { try SaveGame.load(from: folder, game: game, encoding: data.encoding, textLanguage: data.languageID * 2) }
            }.value
            switch result {
            case .success(let loaded):
                baseline = loaded
                save = loaded
                changeCount = 0
                changeNames = []
                state = .ready
            case .failure(let error):
                state = .failed(error.localizedDescription)
            }
            refreshVersions(using: model)
        }
    }

    /// Discards edits and reads the save from disk again.
    func reload(using model: AppModel) {
        undoManager?.removeAllActions(withTarget: self)
        model.invalidateThumbnail(for: id)
        load(using: model)
    }

    func refreshVersions(using model: AppModel) {
        let store = model.versionStore, folder = summary.folder
        Task {
            let (list, current) = await Task.detached(priority: .utility) {
                (store.versions(for: folder), store.currentState(of: folder))
            }.value
            versions = list
            currentState = current
        }
    }

    // MARK: Editing

    /// Applies an undoable change to the save.
    func edit(_ action: String, _ change: (inout SaveGame) -> Void) {
        guard var updated = save else { return }
        let previous = updated
        change(&updated)
        apply(updated, replacing: previous, action: action, delta: 1)
    }

    private func apply(_ new: SaveGame, replacing old: SaveGame, action: String, delta: Int) {
        save = new
        changeCount += delta
        if delta > 0 { changeNames.append(action) } else if !changeNames.isEmpty { changeNames.removeLast() }
        undoManager?.registerUndo(withTarget: self) { document in
            MainActor.assumeIsolated { document.apply(old, replacing: new, action: action, delta: -delta) }
        }
        undoManager?.setActionName(action)
    }

    func revert() {
        guard let baseline else { return }
        undoManager?.removeAllActions(withTarget: self)
        save = baseline
        changeCount = 0
        changeNames = []
    }

    /// A binding that edits the save through `edit`, for controls that commit discrete values.
    func binding<Value: Equatable>(_ action: String, _ get: @escaping (SaveGame) -> Value?, fallback: Value? = nil,
                                   _ set: @escaping (inout SaveGame, Value) -> Void) -> Binding<Value> {
        let initial = save.flatMap(get) ?? fallback
        return Binding(
            get: { [weak self] in
                if let save = self?.save, let value = get(save) { return value }
                guard let initial else { preconditionFailure("A binding was made for a value the save does not have") }
                return initial
            },
            set: { [weak self] value in
                guard let self, let save, get(save) != value else { return }
                edit(action) { set(&$0, value) }
            })
    }

    // MARK: Writing

    func commit(using model: AppModel, overwriteExternalChanges: Bool = false) async {
        guard let save, let baseline, !isSaving, isDirty else { return }
        isSaving = true
        defer { isSaving = false }
        let store = model.versionStore, summaryText = changeSummary, retention = model.preferences.versionRetention
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try SaveWriter.commit(save, baseline: baseline, store: store, summary: summaryText, retention: retention,
                                      overwriteExternalChanges: overwriteExternalChanges)
            }.value
            self.baseline = result.reloaded
            self.save = result.reloaded
            changeCount = 0
            changeNames = []
            externalChanges = nil
            if let updated = try? SaveSummary.read(folder: summary.folder, game: location.game, encoding: result.reloaded.encoding) {
                summary = updated
            }
            model.scan(location)
            refreshVersions(using: model)
        } catch CommitError.externallyModified(let files) {
            externalChanges = files
        } catch {
            errorMessage = error.localizedDescription
            refreshVersions(using: model)
        }
    }

    func restore(_ version: SaveVersion, using model: AppModel) {
        let store = model.versionStore, folder = summary.folder
        Task {
            do {
                try await Task.detached(priority: .userInitiated) { _ = try store.restore(version, to: folder) }.value
                reload(using: model)
                model.scan(location)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func delete(_ version: SaveVersion, using model: AppModel) {
        do {
            try model.versionStore.delete(version, for: summary.folder)
        } catch {
            errorMessage = error.localizedDescription
        }
        refreshVersions(using: model)
    }

    // MARK: Names

    func name(of character: CharacterID) -> String {
        switch character {
        case .player:
            if let name = gameData?.text(save?.creature(.player)?.firstName), !name.isEmpty { return name }
            return "Player"
        case .npc(let index):
            if let name = gameData?.text(save?.creature(.npc(index))?.firstName), !name.isEmpty { return name }
            return companionName(index)
        }
    }

    /// A companion slot's name: the sheet's name when present, else the standard name.
    func companionName(_ index: Int) -> String {
        if save?.npcs[index] != nil, let name = gameData?.text(save?.creature(.npc(index))?.firstName), !name.isEmpty { return name }
        return game.standardNPCNames[index] ?? "Companion \(index + 1)"
    }
}
