import AppKit
import Aurora
import KotORSave
import Observation
import SwiftUI

struct LocationState {
    var summaries: [SaveSummary] = []
    var error: String?
    var isLoading = false
}

struct InventoryClipboard {
    var sourceName: String
    var game: Game
    var items: [GFFStruct]
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

    let versionStore = SaveVersionStore()
    @ObservationIgnored private var gameDataTasks: [Game: Task<GameData, Never>] = [:]
    @ObservationIgnored private var thumbnailRequests: Set<String> = []

    init() {
        preferences = .load()
        Game.allCases.forEach { _ = loadGameData($0) }
        refresh()
    }

    var selectedDocument: SaveDocument? { selectedSaveID.flatMap { documents[$0] } }
    var dirtyDocuments: [SaveDocument] { documents.values.filter(\.isDirty).sorted { $0.summary.name < $1.summary.name } }

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
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<[SaveSummary], Error> in
                Result {
                    _ = try FileManager.default.contentsOfDirectory(atPath: location.url.path)
                    return SaveDiscovery.saveFolders(in: location.url)
                        .compactMap { try? SaveSummary.read(folder: $0, game: location.game, encoding: encoding) }
                        .sorted { $0.modified > $1.modified }
                }
            }.value
            var state = LocationState()
            switch result {
            case .success(let summaries): state.summaries = summaries
            case .failure(let error): state.error = Self.describe(error, at: location.url)
            }
            locationStates[location.id] = state
            for summary in state.summaries { documents[summary.id]?.summary = summary }
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

    static func describe(_ error: Error, at url: URL) -> String {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileReadNoPermissionError {
            return "macOS blocked access to this folder. Allow Kool Save Editor to access data from other apps in System Settings › Privacy & Security, then refresh."
        }
        return error.localizedDescription
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
        guard let id = selectedSaveID, documents[id] == nil, let (summary, location) = location(for: id) else { return }
        let document = SaveDocument(summary: summary, location: location)
        documents[id] = document
        document.load(using: self)
    }

    func closeDocument(_ document: SaveDocument) {
        documents[document.id] = nil
        if selectedSaveID == document.id { openSelected() }
    }

    /// Saves every edited save. Returns false if any save failed.
    func saveAll() async -> Bool {
        var succeeded = true
        for document in dirtyDocuments {
            await document.commit(using: self)
            if document.isDirty { succeeded = false }
        }
        return succeeded
    }

    // MARK: Thumbnails

    func loadThumbnail(for summary: SaveSummary) {
        guard thumbnails[summary.id] == nil, thumbnailRequests.insert(summary.id).inserted else { return }
        let folder = summary.folder
        Task {
            let image = await Task.detached(priority: .utility) { SaveGame.screenshot(in: folder) }.value
            if let image = image?.nsImage { thumbnails[summary.id] = image }
        }
    }

    func invalidateThumbnail(for id: String) {
        thumbnails[id] = nil
        thumbnailRequests.remove(id)
    }

    // MARK: Inventory clipboard

    func copyInventory(from document: SaveDocument) {
        guard let save = document.save else { return }
        inventoryClipboard = InventoryClipboard(sourceName: document.summary.name, game: save.game,
                                                items: save.inventory?.root.list("ItemList") ?? [])
    }

    func canPasteInventory(into document: SaveDocument?) -> Bool {
        guard let clipboard = inventoryClipboard, let save = document?.save else { return false }
        return clipboard.game == save.game
    }

    func pasteInventory(into document: SaveDocument) {
        guard canPasteInventory(into: document), let clipboard = inventoryClipboard else { return }
        document.edit("Paste Inventory") { $0.replaceInventory(with: clipboard.items) }
    }
}
