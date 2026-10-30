import AppKit
import Aurora
import KotORSave
import Observation
import SwiftUI

struct LocationState {
    var summaries: [SaveSummary] = []
    /// Why the folder can't be read, short enough for the sidebar; `errorHelp` has the details.
    var error: String?
    var errorHelp: String?
    /// macOS privacy protection blocks the folder; System Settings can allow access.
    var isBlockedByPrivacy = false
    var isLoading = false
}

struct InventoryClipboard {
    var sourceName: String
    var game: Game
    var items: [GFFStruct]
}

/// Revert to Saved or Reload from Disk on a save with unsaved edits, waiting for the user to
/// confirm that the edits are discarded.
struct DiscardRequest {
    enum Action {
        case revert
        case reload
    }

    let document: SaveDocument
    let action: Action
}

@Observable
final class AppModel {
    var preferences: Preferences {
        didSet {
            guard preferences != oldValue else { return }
            preferences.save()
            if preferences.gameFolders != oldValue.gameFolders || preferences.encodingID != oldValue.encodingID {
                Game.allCases.forEach { _ = loadGameData($0, force: true) }
            }
            if preferences.customFolders != oldValue.customFolders { refresh() }
        }
    }

    private(set) var locations: [SaveLocation] = []
    private(set) var locationStates: [String: LocationState] = [:]
    private(set) var gameData: [Game: GameData] = [:]
    private(set) var detectedGameFolders: [Game: URL] = [:]
    private(set) var thumbnails: [String: NSImage] = [:]
    private(set) var documents: [String: SaveDocument] = [:]
    var selectedSaveID: String? {
        didSet { if selectedSaveID != oldValue { openSelected() } }
    }
    var inventoryClipboard: InventoryClipboard?
    var errorMessage: String?
    /// Shown by the window's confirmation: discarding edits (Revert, Reload) and Paste Inventory….
    var pendingDiscard: DiscardRequest?
    var pendingPaste: SaveDocument?
    /// Text typed into a name field that is not applied yet (see `CommitTextField`).
    private(set) var typing: TypedText?

    let versionStore = SaveVersionStore()
    let gameMonitor = GameMonitor()
    @ObservationIgnored private var gameDataTasks: [Game: Task<GameData, Never>] = [:]
    @ObservationIgnored private var thumbnailRequests: Set<String> = []
    @ObservationIgnored private var thumbnailReads: Set<String> = []
    @ObservationIgnored private var scanGenerations: [String: Int] = [:]

    init() {
        preferences = .load()
        Game.allCases.forEach { _ = loadGameData($0) }
        refresh()
        // A game that quits may have saved over the slots.
        gameMonitor.didQuit = { [weak self] _ in self?.refresh() }
    }

    var selectedDocument: SaveDocument? { selectedSaveID.flatMap { documents[$0] } }
    var dirtyDocuments: [SaveDocument] { documents.values.filter(\.isDirty).sorted { $0.summary.name < $1.summary.name } }

    /// A running game overwrites its saves with its own copy, so they aren't written while it runs.
    func isGameRunning(_ game: Game) -> Bool { gameMonitor.isRunning(game) }

    // MARK: Save locations

    /// Debug aid: `-KSEMacSavesFolder <path>` shows only that saves folder and
    /// `-KSEMacGameFolder <path>` overrides the game folders (used for screenshots and UI checks).
    static var savesFolderOverride: URL? { UserDefaults.standard.string(forKey: "KSEMacSavesFolder").map { URL(fileURLWithPath: $0) } }
    static var gameFolderOverride: URL? { UserDefaults.standard.string(forKey: "KSEMacGameFolder").map { URL(fileURLWithPath: $0) } }

    func refresh() {
        let custom = preferences.customFolders.map { SaveLocation(game: $0.game, source: .custom, url: URL(fileURLWithPath: $0.path)) }
        let override = Self.savesFolderOverride
        Task {
            // Discovery touches other apps' containers, which can block on a privacy prompt.
            let discovered = await Task.detached(priority: .userInitiated) { () -> [SaveLocation] in
                if let override {
                    let game = SaveDiscovery.saveFolders(in: override).lazy.compactMap(SaveGame.detectGame(in:)).first ?? .kotor1
                    return [SaveLocation(game: game, source: .custom, url: override)]
                }
                return SaveDiscovery.defaultLocations() + custom
            }.value
            var seen = Set<String>()
            locations = discovered.filter { seen.insert($0.id).inserted }
            locationStates = locationStates.filter { key, _ in seen.contains(key) }
            locations.forEach(scan)
        }
    }

    func scan(_ location: SaveLocation) {
        locationStates[location.id, default: LocationState()].isLoading = true
        let encoding = gameData[location.game]?.encoding ?? .windows1252
        let generation = (scanGenerations[location.id] ?? 0) + 1
        scanGenerations[location.id] = generation
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<[SaveSummary], Error> in
                Result {
                    _ = try FileManager.default.contentsOfDirectory(atPath: location.url.path)
                    return SaveDiscovery.saveFolders(in: location.url)
                        .compactMap { try? SaveSummary.read(folder: $0, game: location.game, encoding: encoding) }
                        .sorted { $0.modified > $1.modified }
                }
            }.value
            // Scans overlap (a game quitting and the app becoming active both refresh): only the
            // newest one describes the folder.
            guard scanGenerations[location.id] == generation else { return }
            var state = LocationState()
            switch result {
            case .success(let summaries): state.summaries = summaries
            case .failure(let error):
                let problem = Self.describe(error, at: location.url)
                state.error = problem.message
                state.errorHelp = problem.help
                state.isBlockedByPrivacy = problem.isPrivacy
            }
            let previous = locationStates[location.id]?.summaries ?? []
            locationStates[location.id] = state
            for summary in state.summaries { documents[summary.id]?.summary = summary }
            // Saves rewritten since they were opened or listed (the game saved over them, or Steam
            // Cloud downloaded them): open ones are read again, and so are their screenshots.
            for document in documents.values where document.location.id == location.id {
                document.reloadIfChangedOnDisk(using: self)
            }
            for summary in state.summaries where previous.contains(where: { $0.id == summary.id && $0 != summary }) {
                invalidateThumbnail(for: summary.id)
            }
            #if DEBUG
            if Self.savesFolderOverride != nil, selectedSaveID == nil, let first = state.summaries.first {
                selectedSaveID = first.id
                documents[first.id]?.section = Self.debugSection
                NSApp.activate(ignoringOtherApps: true)
                if UserDefaults.standard.bool(forKey: "KSEMacShowAbout") { AboutPanel.show() }
            }
            #endif
        }
    }

    #if DEBUG
    /// `-KSEMacSection player|npc|party|inventory|journal|globals|versions` opens a section at launch.
    static var debugSection: SaveSection {
        switch UserDefaults.standard.string(forKey: "KSEMacSection") {
        case "player": .character(.player)
        case "npc": .character(.npc(2))
        case "party": .party
        case "inventory": .inventory
        case "journal": .journal
        case "globals": .globals
        case "versions": .versions
        default: .summary
        }
    }
    #endif

    /// A short message for the sidebar and the details for its help button.
    static func describe(_ error: Error, at url: URL) -> (message: String, help: String, isPrivacy: Bool) {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileReadNoPermissionError {
            return ("Access blocked by macOS",
                    "macOS keeps apps out of other apps’ data unless you allow it. Click ? for how to allow access in System Settings.",
                    true)
        }
        return ("Can’t read this folder", error.localizedDescription, false)
    }

    func location(for id: String) -> (SaveSummary, SaveLocation)? {
        for location in locations {
            if let summary = locationStates[location.id]?.summaries.first(where: { $0.id == id }) { return (summary, location) }
        }
        return nil
    }

    func addCustomFolder(_ url: URL) {
        var folder = url.standardizedFileURL
        if FileManager.default.caseInsensitiveItem(named: "savenfo.res", in: folder) != nil {
            folder = folder.deletingLastPathComponent()
        }
        guard let game = SaveDiscovery.saveFolders(in: folder).lazy.compactMap(SaveGame.detectGame(in:)).first else {
            errorMessage = "No KotOR saves were found in “\(folder.lastPathComponent)”."
            return
        }
        guard !locations.contains(where: { $0.id == folder.path }) else { return }
        preferences.customFolders.append(.init(path: folder.path, game: game))
    }

    func removeCustomFolder(_ location: SaveLocation) {
        preferences.customFolders.removeAll { $0.path == location.url.path }
    }

    func chooseCustomFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a KotOR “saves” folder, or a single save inside one."
        panel.prompt = "Add Folder"
        if panel.runModal() == .OK, let url = panel.url { addCustomFolder(url) }
    }

    // MARK: Game data

    func gameFolder(for game: Game) -> URL? {
        preferences.gameFolder(for: game) ?? detectedGameFolders[game]
    }

    @discardableResult
    func loadGameData(_ game: Game, force: Bool = false) -> Task<GameData, Never> {
        if !force, let task = gameDataTasks[game] { return task }
        let explicit = Self.gameFolderOverride ?? preferences.gameFolder(for: game)
        let encoding = preferences.encodingID.flatMap(TextEncoding.named)
        let task = Task.detached(priority: .userInitiated) { () -> GameData in
            let root = explicit ?? SaveDiscovery.gameDataCandidates(for: game).first
            return GameData(game: game, root: root, encoding: encoding)
        }
        gameDataTasks[game] = task
        Task {
            let data = await task.value
            guard gameDataTasks[game] == task else { return }
            gameData[game] = data
            if explicit == nil { detectedGameFolders[game] = data.root }
            for document in documents.values where document.location.game == game { document.gameData = data }
        }
        return task
    }

    // MARK: Documents

    private func openSelected() {
        guard let id = selectedSaveID else { return }
        if let document = documents[id] {
            // Already open: the game may have saved over it while another save was selected.
            document.reloadIfChangedOnDisk(using: self)
            return
        }
        guard let (summary, location) = location(for: id) else { return }
        let document = SaveDocument(summary: summary, location: location)
        documents[id] = document
        document.load(using: self)
    }

    func closeDocument(_ document: SaveDocument) {
        documents[document.id] = nil
        if selectedSaveID == document.id { openSelected() }
    }

    /// Whether Save and Revert have something to act on, counting text still being typed (which
    /// only ever belongs to the selected save: a field applies its text when it goes away).
    func hasUnsavedChanges(_ document: SaveDocument?) -> Bool {
        guard let document else { return false }
        return document.isDirty || (typing != nil && document === selectedDocument)
    }

    /// Revert to Saved: puts back the save as loaded or last saved, after asking when that
    /// discards edits.
    func requestRevert(_ document: SaveDocument) {
        commitTyping()
        guard document.isDirty else { return }
        pendingDiscard = DiscardRequest(document: document, action: .revert)
    }

    /// Reload from Disk: reads the save again, at once when it has no edits, else after asking.
    func requestReload(_ document: SaveDocument) {
        commitTyping()
        let request = DiscardRequest(document: document, action: .reload)
        if document.isDirty { pendingDiscard = request } else { discard(request) }
    }

    func discard(_ request: DiscardRequest) {
        pendingDiscard = nil
        switch request.action {
        case .revert: request.document.revert()
        case .reload: request.document.reload(using: self)
        }
    }

    /// Saves every edited save, or just `documents`. Returns false if any save failed.
    func saveAll(_ documents: [SaveDocument]? = nil) async -> Bool {
        var succeeded = true
        for document in documents ?? dirtyDocuments {
            await document.commit(using: self)
            if document.isDirty { succeeded = false }
        }
        return succeeded
    }

    // MARK: Thumbnails

    func loadThumbnail(for summary: SaveSummary) {
        guard thumbnails[summary.id] == nil, thumbnailRequests.insert(summary.id).inserted else { return }
        readThumbnail(summary)
    }

    /// Reads a save's screenshot again after the save was rewritten; the old one shows until
    /// then. Thumbnails not shown yet are read when they are.
    func invalidateThumbnail(for id: String) {
        guard thumbnailRequests.contains(id), let (summary, _) = location(for: id) else { return }
        readThumbnail(summary)
    }

    private func readThumbnail(_ summary: SaveSummary) {
        guard thumbnailReads.insert(summary.id).inserted else { return }
        let folder = summary.folder
        Task {
            let image = await Task.detached(priority: .utility) { SaveGame.screenshot(in: folder) }.value
            thumbnailReads.remove(summary.id)
            thumbnails[summary.id] = image?.nsImage
        }
    }

    // MARK: Inventory clipboard

    func copyInventory(from document: SaveDocument) {
        guard let save = document.save else { return }
        inventoryClipboard = InventoryClipboard(sourceName: document.summary.name, game: save.game,
                                                items: save.inventory?.root.list("ItemList") ?? [])
    }

    func canPasteInventory(into document: SaveDocument?) -> Bool {
        // Not while the save is (re)loading: it would paste into the copy being replaced.
        guard let clipboard = inventoryClipboard, let document, document.isReady, let save = document.save else { return false }
        return clipboard.game == save.game
    }

    /// Paste Inventory… from the Inventory section, the Savegame menu or the save list: selects the
    /// save and shows its inventory, then asks. Only the selected save has the window's undo
    /// manager, so this is what makes the paste undoable.
    func requestPasteInventory(into document: SaveDocument) {
        guard canPasteInventory(into: document) else { return }
        selectedSaveID = document.id
        document.section = .inventory
        pendingPaste = document
    }

    func pasteInventory(into document: SaveDocument) {
        pendingPaste = nil
        guard document === selectedDocument, canPasteInventory(into: document), let clipboard = inventoryClipboard else { return }
        document.edit("Paste Inventory") { $0.replaceInventory(with: clipboard.items) }
    }

    /// Quest items in a save's inventory that the copied inventory doesn't have (by tag), which
    /// pasting removes.
    func questItemsLostByPasting(into document: SaveDocument) -> Int {
        guard let save = document.save, let clipboard = inventoryClipboard else { return 0 }
        let encoding = save.encoding
        let pasted = Set(clipboard.items.compactMap { $0.string("Tag", encoding: encoding)?.lowercased() })
        return (save.inventory?.root.list("ItemList") ?? []).filter { item in
            (item.integer("Plot") ?? 0) != 0 && !pasted.contains(item.string("Tag", encoding: encoding)?.lowercased() ?? "")
        }.count
    }

    // MARK: Typing

    func beginTyping(_ text: TypedText) {
        if let typing, typing !== text { finishTyping(typing) }
        typing = text
    }

    /// Applies typed text (if it changed anything) to the save and character it was typed for.
    func finishTyping(_ text: TypedText, endingEditing: Bool = false) {
        text.finish(endingEditing: endingEditing)
        if typing === text { typing = nil }
    }

    /// Applies the text being typed, if any, and ends editing: Save, Revert, Reload and Quit
    /// call this first, so typed text is neither lost nor applied later on top of their result.
    func commitTyping() {
        if let typing { finishTyping(typing, endingEditing: true) }
    }
}
