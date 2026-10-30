// KSEMac — a KotOR savegame editor for macOS.
// Loading and re-serializing a save folder, following KSE's Populate_Level1 and
// CommitChanges (https://gitlab.com/kotorsge-team/kse). GNU GPL v3 or later.
//
// A save folder holds savenfo.res, PARTYTABLE.res, GLOBALVARS.res, Screen.tga and
// SAVEGAME.sav. SAVEGAME.sav is an ERF containing INVENTORY.res, the companions'
// AVAILNPC<n>.utc sheets and one nested ERF per visited module; the player character
// lives in Module.ifo inside the nested ERF named by savenfo's LASTMODULE.
// Unlike KSE, only files whose contents changed are rewritten, except when the editor's
// version replaces a save changed outside it: then every file is.
//
// The game doesn't always go on with those sheets, and the editor can't edit the copies it
// uses instead yet, so it finds them for the sheets to say so: a TSL transition autosave
// (savenfo PCAUTOSAVE) keeps the current player in pifo.ifo next to SAVEGAME.sav, leaving an
// older copy in Module.ifo; while the player controls a companion (PARTYTABLE
// PT_CONTROLLED_NP), Mod_PlayerList holds that companion and the player character is in
// pc.utc; companions standing in the current area (aboard the Ebon Hawk) have a copy in its
// .git that the game uses instead of their AVAILNPC sheet.

import Aurora
import Foundation

public enum SaveGameError: Error, LocalizedError, Equatable {
    case missingFile(String)
    case missingModule(String)
    case damaged(String, String)

    public var errorDescription: String? {
        switch self {
        case .missingFile(let name): "The save is missing \(name)."
        case .missingModule(let name): "The save's current module (\(name).sav) is missing from SAVEGAME.sav."
        case .damaged(let name, let reason): "\(name) could not be read: \(reason)"
        }
    }
}

/// Size and modification date of a file when it was read, to detect outside changes.
public struct FileFingerprint: Sendable, Hashable {
    public var size: Int
    public var modified: Date?

    public init(url: URL) {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        size = values?.fileSize ?? -1
        modified = values?.contentModificationDate
    }
}

public struct SaveFileNames: Sendable, Hashable {
    public var info: String
    public var party: String
    public var globals: String?
    public var archive: String
    public var screenshot: String?
    public var signatures: [String]
    /// pifo.ifo: in a transition autosave, the player the game goes on with.
    public var playerIFO: String?

    public init(folder: URL) throws {
        let items = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        func find(_ name: String) -> String? { items.first { $0.lowercased() == name } }
        guard let info = find("savenfo.res") else { throw SaveGameError.missingFile("savenfo.res") }
        guard let party = find("partytable.res") else { throw SaveGameError.missingFile("PARTYTABLE.res") }
        guard let archive = find("savegame.sav") else { throw SaveGameError.missingFile("SAVEGAME.sav") }
        self.info = info
        self.party = party
        self.archive = archive
        globals = find("globalvars.res")
        screenshot = find("screen.tga")
        signatures = items.filter { $0.lowercased().hasSuffix(".sig") }.sorted()
        playerIFO = find("pifo.ifo")
    }

    /// Every file the editor reads or writes, and pifo.ifo, so outside changes to any are noticed.
    public var all: [String] {
        [info, party, globals, archive, screenshot, playerIFO].compactMap { $0 } + signatures
    }
}

public struct SaveGame: Sendable {
    public let folder: URL
    public let game: Game
    public let encoding: TextEncoding
    /// Locstring language ID (`language * 2`) used for names the user types.
    public let textLanguage: UInt32
    public let fileNames: SaveFileNames
    /// Every file of the save when it was read (the files a version keeps).
    public let fingerprints: [String: FileFingerprint]
    /// The save's files that aren't parsed or signatures (Screen.tga), as read: written back
    /// when the editor's version replaces a save changed outside it.
    public let otherFiles: [String: [UInt8]]

    public var info: GFFDocument
    public var party: GFFDocument
    public var globals: GFFDocument?
    public var archive: ERFArchive
    public let moduleResRef: String
    public var moduleArchive: ERFArchive
    public var module: GFFDocument
    public var inventory: GFFDocument?
    public var npcs: [Int: GFFDocument]

    /// A transition autosave (savenfo PCAUTOSAVE with a pifo.ifo in the folder): the game goes
    /// on with the player in pifo.ifo, and the player sheet in Module.ifo is an older copy.
    public let isPCAutosave: Bool
    /// The companion the player controls when the player sheet is that companion's copy (it has
    /// their tag; PARTYTABLE PT_CONTROLLED_NP); the player character is then kept in pc.utc.
    public let controlledCompanion: Int?
    /// Companions with a copy standing in the current area (a creature with their tag in one of
    /// the module's .git files, as aboard the Ebon Hawk): the game uses that copy, not their sheet.
    public let companionsInArea: Set<Int>

    public static func load(from folder: URL, game: Game? = nil, encoding: TextEncoding = .windows1252,
                            textLanguage: UInt32 = 0) throws -> SaveGame {
        let names = try SaveFileNames(folder: folder)
        let parsed = Set(([names.info, names.party, names.globals, names.archive].compactMap { $0 } + names.signatures).map { $0.lowercased() })
        let others = ((try? SaveVersionStore.saveFiles(in: folder)) ?? []).filter { !parsed.contains($0.lowercased()) }
        var fingerprints: [String: FileFingerprint] = [:]
        for name in names.all + others { fingerprints[name] = FileFingerprint(url: folder.appendingPathComponent(name)) }

        func read(_ name: String) throws -> [UInt8] {
            do { return [UInt8](try Data(contentsOf: folder.appendingPathComponent(name))) } catch {
                throw SaveGameError.damaged(name, error.localizedDescription)
            }
        }
        func gff(_ name: String, _ bytes: [UInt8]) throws -> GFFDocument {
            do { return try GFFDocument(bytes: bytes) } catch { throw SaveGameError.damaged(name, error.localizedDescription) }
        }

        let info = try gff(names.info, try read(names.info))
        let party = try gff(names.party, try read(names.party))
        let globals = try names.globals.map { try gff($0, try read($0)) }
        let archive: ERFArchive
        do { archive = try ERFArchive(bytes: try read(names.archive)) } catch let error as SaveGameError { throw error } catch {
            throw SaveGameError.damaged(names.archive, error.localizedDescription)
        }

        let moduleResRef = info.root.string("LASTMODULE", encoding: encoding) ?? ""
        guard let moduleBytes = archive.data(for: moduleResRef, type: .sav) else {
            throw SaveGameError.missingModule(moduleResRef)
        }
        let moduleArchive: ERFArchive
        do { moduleArchive = try ERFArchive(bytes: moduleBytes) } catch {
            throw SaveGameError.damaged("\(moduleResRef).sav", error.localizedDescription)
        }
        guard let ifoBytes = moduleArchive.data(for: "module", type: .ifo) else {
            throw SaveGameError.missingFile("Module.ifo in \(moduleResRef).sav")
        }
        let module = try gff("Module.ifo", ifoBytes)
        let inventory = try archive.data(for: "inventory", type: .res).map { try gff("INVENTORY.res", $0) }

        var npcs: [Int: GFFDocument] = [:]
        for resource in archive.resources where resource.type == .utc {
            let name = resource.resRef.lowercased()
            guard name.hasPrefix("availnpc"), let index = Int(name.dropFirst(8)) else { continue }
            npcs[index] = try gff(resource.fileName, resource.data)
        }
        var otherFiles: [String: [UInt8]] = [:]
        for name in others { otherFiles[name] = try? read(name) }

        return SaveGame(folder: folder, game: game ?? detectGame(info: info, party: party), encoding: encoding, textLanguage: textLanguage,
                        fileNames: names, fingerprints: fingerprints, otherFiles: otherFiles, info: info, party: party, globals: globals,
                        archive: archive, moduleResRef: moduleResRef, moduleArchive: moduleArchive, module: module,
                        inventory: inventory, npcs: npcs,
                        isPCAutosave: names.playerIFO != nil && (info.root.integer("PCAUTOSAVE") ?? 0) != 0,
                        controlledCompanion: detectControlledCompanion(party: party, module: module, npcs: npcs, encoding: encoding),
                        companionsInArea: detectCompanionsInArea(moduleArchive, npcs: npcs, encoding: encoding))
    }

    /// The companion whose copy the player sheet is: the sheet has a tag (the player character's
    /// is empty in every real save checked, both games), matched ignoring case against the
    /// companions' sheets, else PT_CONTROLLED_NP. The tag comes first because the party edits of
    /// Kool Save Editor 1.1 reset PT_CONTROLLED_NP when that companion left the party.
    static func detectControlledCompanion(party: GFFDocument, module: GFFDocument, npcs: [Int: GFFDocument],
                                          encoding: TextEncoding) -> Int? {
        guard let tag = module.root.list("Mod_PlayerList")?.first?.string("Tag", encoding: encoding)?.lowercased(),
              !tag.isEmpty else { return nil }
        if let index = npcs.keys.sorted().first(where: { npcs[$0]?.root.string("Tag", encoding: encoding)?.lowercased() == tag }) {
            return index
        }
        guard let index = party.root.integer("PT_CONTROLLED_NP"), index >= 0 else { return nil }
        return index
    }

    /// Companions whose tag (ignoring case) is on a creature in one of the module's .git files.
    /// An unreadable .git is skipped: it only costs a notice, not the save.
    static func detectCompanionsInArea(_ module: ERFArchive, npcs: [Int: GFFDocument], encoding: TextEncoding) -> Set<Int> {
        var tags = Set<String>()
        for resource in module.resources where resource.type == .git {
            guard let git = try? GFFDocument(bytes: resource.data) else { continue }
            for creature in git.root.list("Creature List") ?? [] {
                if let tag = creature.string("Tag", encoding: encoding), !tag.isEmpty { tags.insert(tag.lowercased()) }
            }
        }
        return Set(npcs.compactMap { index, npc in
            guard let tag = npc.root.string("Tag", encoding: encoding), !tag.isEmpty, tags.contains(tag.lowercased()) else { return nil }
            return index
        })
    }

    /// TSL saves carry influence, the player name in savenfo and twelve companion slots.
    public static func detectGame(info: GFFDocument, party: GFFDocument) -> Game {
        party.root.has("PT_INFLUENCE") || info.root.has("PCNAME") || (party.root.list("PT_AVAIL_NPCS")?.count ?? 0) > 9
            ? .kotor2 : .kotor1
    }

    /// Reads just enough of a save folder to tell which game wrote it.
    public static func detectGame(in folder: URL) -> Game? {
        guard let names = try? SaveFileNames(folder: folder),
              let info = try? GFFDocument(data: Data(contentsOf: folder.appendingPathComponent(names.info))),
              let party = try? GFFDocument(data: Data(contentsOf: folder.appendingPathComponent(names.party))) else { return nil }
        return detectGame(info: info, party: party)
    }

    /// The bytes of every file whose contents differ from `baseline`, the save as last read.
    /// SAVEGAME.sav is rebuilt from the baseline's archives, replacing only the resources whose
    /// documents changed: this copy's own archives can be older than the files on disk (undoing
    /// past a save brings back a copy taken before it), so they are never written.
    public func changedFiles(since baseline: SaveGame) -> [String: [UInt8]] {
        files(since: baseline, includingUnchanged: false)
    }

    /// Every file of the save as the editor holds it: the save as read into `baseline` plus the
    /// edits, with unchanged documents re-encoded and the other files as they were read. Replaces
    /// a save changed outside the editor (the game saving over it) as a whole, not file by file.
    public func allFiles(since baseline: SaveGame) -> [String: [UInt8]] {
        files(since: baseline, includingUnchanged: true)
    }

    private func files(since baseline: SaveGame, includingUnchanged all: Bool) -> [String: [UInt8]] {
        var files = all ? baseline.otherFiles : [:]
        if all || info != baseline.info { files[fileNames.info] = info.encoded() }
        if all || party != baseline.party { files[fileNames.party] = party.encoded() }
        if let globals, let name = fileNames.globals, all || globals != baseline.globals { files[name] = globals.encoded() }

        var outer = baseline.archive
        var outerChanged = all
        if module != baseline.module {
            var inner = baseline.moduleArchive
            inner.setData(module.encoded(), for: "module", type: .ifo)
            outer.setData(inner.encoded(), for: moduleResRef, type: .sav)
            outerChanged = true
        }
        if inventory != baseline.inventory {
            if let inventory {
                outer.setData(inventory.encoded(), for: "INVENTORY", type: .res)
            } else if let index = outer.index(of: "INVENTORY", type: .res) {
                // Undoing past the save that added the inventory.
                outer.resources.remove(at: index)
            }
            outerChanged = true
        }
        for (index, npc) in npcs.sorted(by: { $0.key < $1.key }) where npc != baseline.npcs[index] {
            outer.setData(npc.encoded(), for: "AVAILNPC\(index)", type: .utc)
            outerChanged = true
        }
        if outerChanged { files[fileNames.archive] = outer.encoded() }
        return files
    }

    /// Whether any parsed document differs from `baseline`. Like `changedFiles`, it ignores the
    /// archives this copy carries.
    public func hasChanges(since baseline: SaveGame) -> Bool {
        info != baseline.info || party != baseline.party || globals != baseline.globals || module != baseline.module
            || inventory != baseline.inventory || npcs != baseline.npcs
    }

    /// Files that were changed, replaced or removed on disk since this save was read.
    public func externallyModifiedFiles() -> [String] {
        fingerprints.compactMap { name, print in
            FileFingerprint(url: folder.appendingPathComponent(name)) == print ? nil : name
        }.sorted()
    }

    public static func screenshot(in folder: URL) -> RGBAImage? {
        guard let file = FileManager.default.caseInsensitiveItem(named: "screen.tga", in: folder),
              let data = try? Data(contentsOf: file) else { return nil }
        return try? TGADecoder.decode([UInt8](data))
    }
}

/// What the save browser shows for a save without loading SAVEGAME.sav.
public struct SaveSummary: Sendable, Hashable, Identifiable {
    public var folder: URL
    public var game: Game
    public var name: String
    public var area: String
    public var module: String
    public var timePlayed: Int
    public var modified: Date
    public var playerName: String?
    public var cheated: Bool

    public var id: String { folder.path }
    public var folderName: String { folder.lastPathComponent }

    public static func read(folder: URL, game: Game, encoding: TextEncoding = .windows1252) throws -> SaveSummary {
        let names = try SaveFileNames(folder: folder)
        let info = try GFFDocument(data: Data(contentsOf: folder.appendingPathComponent(names.info)))
        let modified = [names.info, names.archive].compactMap {
            FileFingerprint(url: folder.appendingPathComponent($0)).modified
        }.max() ?? .distantPast
        let saveName = info.root.string("SAVEGAMENAME", encoding: encoding) ?? ""
        return SaveSummary(folder: folder, game: game, name: saveName.isEmpty ? folder.lastPathComponent : saveName,
                           area: info.root.string("AREANAME", encoding: encoding) ?? "",
                           module: info.root.string("LASTMODULE", encoding: encoding) ?? "",
                           timePlayed: info.root.integer("TIMEPLAYED") ?? 0, modified: modified,
                           playerName: info.root.string("PCNAME", encoding: encoding),
                           cheated: (info.root.integer("CHEATUSED") ?? 0) != 0)
    }
}
