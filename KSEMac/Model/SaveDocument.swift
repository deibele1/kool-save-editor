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

    /// A step from the save on disk to the one being edited: an edit, or the undoing of an
    /// edit that was saved.
    struct PendingEdit {
        var id: Int
        var action: String
        var isUndo: Bool
    }

    let id: String
    let location: SaveLocation
    var summary: SaveSummary
    var gameData: GameData?
    var section: SaveSection? = .summary

    private(set) var state: State = .loading
    private(set) var baseline: SaveGame?
    private(set) var save: SaveGame?
    /// Whether the save differs from the one on disk (`baseline`). Kept up to date as either
    /// changes rather than computed, since views read it often.
    private(set) var isDirty = false
    /// The steps from the save on disk to the one being edited, oldest first.
    private(set) var pendingEdits: [PendingEdit] = []
    private(set) var isSaving = false
    private(set) var versions: [SaveVersion] = []
    private(set) var currentState: CurrentSaveState?
    var externalChanges: [String]?
    var errorMessage: String?

    @ObservationIgnored weak var undoManager: UndoManager?
    @ObservationIgnored private var editCount = 0
    /// The files as they were when `reloadIfChangedOnDisk` last reported them or read them again:
    /// each change is reported once, and a read that failed is retried only after they change.
    @ObservationIgnored private var handledDiskState: [String: FileFingerprint]?

    init(summary: SaveSummary, location: SaveLocation) {
        id = summary.id
        self.summary = summary
        self.location = location
    }

    var isReady: Bool { if case .ready = state { true } else { false } }
    var game: Game { save?.game ?? location.game }

    /// A short description of the pending edits, used to label the version saved before writing.
    /// Undoing an edit that was saved is an edit of its own ("Undo …").
    var changeSummary: String {
        var seen = Set<String>()
        let names = pendingEdits.map { $0.isUndo ? "Undo \($0.action)" : $0.action }.filter { seen.insert($0).inserted }
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
                isDirty = false
                pendingEdits = []
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

    /// Reads the save again if its files changed on disk since it was loaded (the game saved over
    /// it, or Steam Cloud downloaded it). Without edits that happens right away, and a read that
    /// failed (the game may still have been writing) is retried once the files change again. With
    /// edits the user chooses (`externalChanges`), once for each change and only after the game has
    /// quit: until then the edits can't be saved, and its quitting checks the saves again.
    func reloadIfChangedOnDisk(using model: AppModel) {
        guard !isSaving, externalChanges == nil, let baseline else { return }
        let onDisk = diskState(of: baseline)
        switch state {
        case .loading: return
        case .ready: guard onDisk != baseline.fingerprints else { return }
        case .failed: guard onDisk != handledDiskState else { return }
        }
        if isDirty {
            guard isReady, onDisk != handledDiskState, !model.isGameRunning(game) else { return }
            externalChanges = onDisk.keys.filter { onDisk[$0] != baseline.fingerprints[$0] }.sorted()
        } else {
            reload(using: model)
        }
        handledDiskState = onDisk
    }

    /// The fingerprints of the save's files as they are on disk now.
    private func diskState(of baseline: SaveGame) -> [String: FileFingerprint] {
        Dictionary(uniqueKeysWithValues: baseline.fingerprints.keys.map {
            ($0, FileFingerprint(url: baseline.folder.appendingPathComponent($0)))
        })
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
        editCount += 1
        apply(updated, replacing: previous, edit: editCount, action: action, undoing: false)
    }

    /// Takes one step: an edit when it is made or redone, `undoing` it when it is undone. Undo
    /// and Redo work across saves; the dirty state compares the save with the one on disk.
    private func apply(_ new: SaveGame, replacing old: SaveGame, edit: Int, action: String, undoing: Bool) {
        save = new
        isDirty = baseline.map { new.hasChanges(since: $0) } ?? false
        // A step back over the last pending one cancels it.
        if let last = pendingEdits.last, last.id == edit, last.isUndo != undoing {
            pendingEdits.removeLast()
        } else {
            pendingEdits.append(PendingEdit(id: edit, action: action, isUndo: undoing))
        }
        undoManager?.registerUndo(withTarget: self) { document in
            MainActor.assumeIsolated { document.apply(old, replacing: new, edit: edit, action: action, undoing: !undoing) }
        }
        undoManager?.setActionName(action)
    }

    func revert() {
        guard let baseline else { return }
        undoManager?.removeAllActions(withTarget: self)
        save = baseline
        isDirty = false
        pendingEdits = []
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
        let store = model.versionStore, retention = model.preferences.versionRetention
        // Versions name what was written over the save before them; a replace also drops the newer save's progress.
        let summaryText = overwriteExternalChanges ? "Replaced newer save: \(changeSummary)" : changeSummary
        let game = self.game
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                // Checked again right before writing: the game may have started since Save was offered.
                try GameMonitor.checkNotRunning(game)
                return try SaveWriter.commit(save, baseline: baseline, store: store, summary: summaryText, retention: retention,
                                             overwriteExternalChanges: overwriteExternalChanges)
            }.value
            // Undo keeps working past this save: the copies it brings back are compared with this baseline.
            self.baseline = result.reloaded
            self.save = result.reloaded
            isDirty = false
            pendingEdits = []
            externalChanges = nil
            if let updated = try? SaveSummary.read(folder: summary.folder, game: location.game, encoding: result.reloaded.encoding) {
                summary = updated
            }
            model.scan(location)
            refreshVersions(using: model)
        } catch CommitError.externallyModified(let files) {
            // Reported here, so the next refresh doesn't report the same change again.
            handledDiskState = diskState(of: baseline)
            externalChanges = files
        } catch {
            errorMessage = error.localizedDescription
            refreshVersions(using: model)
        }
    }

    func restore(_ version: SaveVersion, using model: AppModel) {
        guard !isSaving else { return }
        let store = model.versionStore, folder = summary.folder, game = self.game
        // A restore writes the save too: nothing else writes it, or reloads it half restored, meanwhile.
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                try await Task.detached(priority: .userInitiated) {
                    // Checked right before writing, as for a save: the game may have started.
                    try GameMonitor.checkNotRunning(game, restoring: true)
                    _ = try store.restore(version, to: folder)
                }.value
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

    /// The player sheet's title in the outline and summary: while the player controls a
    /// companion, the sheet is that companion's copy.
    var playerTitle: String {
        if let index = save?.controlledCompanion { return "Player (controlling \(companionName(index)))" }
        return name(of: .player)
    }

    /// Fills in this save's player name where game text says <FullName>, as the game does. When
    /// the player sheet is another copy (a controlled companion's, or an autosave's older one),
    /// the name comes from the party table, which keeps the player's.
    var textTokens: TextTokens {
        if let save, !save.playerSheetIsCurrent, let name = save.storedPlayerName { return TextTokens(firstName: name) }
        let player = save?.creature(.player)
        return TextTokens(firstName: gameData?.text(player?.firstName) ?? "", lastName: gameData?.text(player?.lastName) ?? "")
    }

    /// A companion slot's name: the sheet's name when present, else the standard name.
    func companionName(_ index: Int) -> String {
        if save?.npcs[index] != nil, let name = gameData?.text(save?.creature(.npc(index))?.firstName), !name.isEmpty { return name }
        return game.standardNPCNames[index] ?? "Companion \(index + 1)"
    }
}
