// KSEMac — a KotOR savegame editor for macOS.
// Loading and re-serializing a save folder, following KSE's Populate_Level1 and
// CommitChanges (https://gitlab.com/kotorsge-team/kse). GNU GPL v3 or later.
//
// A save folder holds savenfo.res, PARTYTABLE.res, GLOBALVARS.res, Screen.tga and
// SAVEGAME.sav. SAVEGAME.sav is an ERF containing INVENTORY.res, the companions'
// AVAILNPC<n>.utc sheets and one nested ERF per visited module; the player character
// lives in Module.ifo inside the nested ERF named by savenfo's LASTMODULE.
// Unlike KSE, only files whose contents changed are rewritten.

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
    }

    /// Every file the editor reads or writes.
    public var all: [String] {
        [info, party, globals, archive, screenshot].compactMap { $0 } + signatures
    }
}

public struct SaveGame: Sendable {
    public let folder: URL
    public let game: Game
    public let encoding: TextEncoding
    /// Locstring language ID (`language * 2`) used for names the user types.
    public let textLanguage: UInt32
    public let fileNames: SaveFileNames
    public let fingerprints: [String: FileFingerprint]

    public var info: GFFDocument
    public var party: GFFDocument
    public var globals: GFFDocument?
    public var archive: ERFArchive
    public let moduleResRef: String
    public var moduleArchive: ERFArchive
    public var module: GFFDocument
    public var inventory: GFFDocument?
    public var npcs: [Int: GFFDocument]

    public static func load(from folder: URL, game: Game? = nil, encoding: TextEncoding = .windows1252,
                            textLanguage: UInt32 = 0) throws -> SaveGame {
        let names = try SaveFileNames(folder: folder)
        var fingerprints: [String: FileFingerprint] = [:]
        for name in names.all { fingerprints[name] = FileFingerprint(url: folder.appendingPathComponent(name)) }

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

        return SaveGame(folder: folder, game: game ?? detectGame(info: info, party: party), encoding: encoding, textLanguage: textLanguage,
                        fileNames: names, fingerprints: fingerprints, info: info, party: party, globals: globals,
                        archive: archive, moduleResRef: moduleResRef, moduleArchive: moduleArchive, module: module,
                        inventory: inventory, npcs: npcs)
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

    /// The bytes of every file whose contents differ from `baseline`.
    public func changedFiles(since baseline: SaveGame) -> [String: [UInt8]] {
        var files: [String: [UInt8]] = [:]
        if info != baseline.info { files[fileNames.info] = info.encoded() }
        if party != baseline.party { files[fileNames.party] = party.encoded() }
        if let globals, let name = fileNames.globals, globals != baseline.globals { files[name] = globals.encoded() }

        var outer = archive
        var outerChanged = archive != baseline.archive
        if module != baseline.module || moduleArchive != baseline.moduleArchive {
            var inner = moduleArchive
            if module != baseline.module { inner.setData(module.encoded(), for: "module", type: .ifo) }
            outer.setData(inner.encoded(), for: moduleResRef, type: .sav)
            outerChanged = true
        }
        if let inventory, inventory != baseline.inventory {
            outer.setData(inventory.encoded(), for: "INVENTORY", type: .res)
            outerChanged = true
        }
        for (index, npc) in npcs.sorted(by: { $0.key < $1.key }) where npc != baseline.npcs[index] {
            outer.setData(npc.encoded(), for: "AVAILNPC\(index)", type: .utc)
            outerChanged = true
        }
        if outerChanged { files[fileNames.archive] = outer.encoded() }
        return files
    }

    public func hasChanges(since baseline: SaveGame) -> Bool {
        info != baseline.info || party != baseline.party || globals != baseline.globals || module != baseline.module
            || inventory != baseline.inventory || npcs != baseline.npcs || archive != baseline.archive
            || moduleArchive != baseline.moduleArchive
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
