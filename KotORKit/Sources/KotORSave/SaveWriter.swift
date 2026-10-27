// KSEMac — a KotOR savegame editor for macOS.
// Writes edited saves safely: snapshot, atomic writes, read-back verification and
// automatic rollback. Xbox signature regeneration follows KSE's CommitChanges
// (https://gitlab.com/kotorsge-team/kse). GNU GPL v3 or later.

import Aurora
import CryptoKit
import Foundation

public enum CommitError: Error, LocalizedError {
    case externallyModified([String])
    case invalidOutput(String, String)
    case writeFailed(String, String, rolledBack: Bool)
    case verificationFailed(String, rolledBack: Bool)

    public var errorDescription: String? {
        switch self {
        case .externallyModified(let files):
            "The save was changed outside the editor (\(files.joined(separator: ", "))). Reload it, or save anyway to overwrite those changes."
        case .invalidOutput(let file, let reason):
            "Nothing was written: the new \(file) failed validation (\(reason))."
        case .writeFailed(let file, let reason, let rolledBack):
            "Writing \(file) failed (\(reason)). " + (rolledBack ? "The save was rolled back to its previous version." : "Rolling back also failed; restore the latest version from the Versions list.")
        case .verificationFailed(let reason, let rolledBack):
            "The written save did not verify (\(reason)). " + (rolledBack ? "The save was rolled back to its previous version." : "Rolling back also failed; restore the latest version from the Versions list.")
        }
    }
}

public struct CommitResult: Sendable {
    /// The snapshot taken before writing, which restores the save to its previous state.
    public var version: SaveVersion?
    public var writtenFiles: [String]
    /// The save as read back from disk, to use as the new baseline.
    public var reloaded: SaveGame
}

public enum SaveWriter {
    public static func commit(_ save: SaveGame, baseline: SaveGame, store: SaveVersionStore, summary: String,
                              retention: Int = 25, overwriteExternalChanges: Bool = false,
                              beforeWriting: ((String) throws -> Void)? = nil) throws -> CommitResult {
        var files = save.changedFiles(since: baseline)
        guard !files.isEmpty else {
            return CommitResult(version: nil, writtenFiles: [], reloaded: save)
        }

        if !overwriteExternalChanges {
            let modified = baseline.externallyModifiedFiles()
            if !modified.isEmpty { throw CommitError.externallyModified(modified) }
        }

        for (name, bytes) in files { try validate(name, bytes, save: save) }

        if !save.fileNames.signatures.isEmpty {
            for (name, bytes) in XboxSignatures.signatures(for: save, replacing: files) { files[name] = bytes }
        }

        let version = try store.snapshot(save.folder, reason: .beforeSave, summary: summary)
        let order = files.keys.sorted()

        func rollback() -> Bool {
            (try? store.restoreFiles(of: version, to: save.folder)) != nil
        }

        for name in order {
            do {
                try beforeWriting?(name)
                try SaveVersionStore.write(Data(files[name]!), to: save.folder.appendingPathComponent(name))
            } catch {
                throw CommitError.writeFailed(name, error.localizedDescription, rolledBack: rollback())
            }
        }

        let reloaded: SaveGame
        do {
            for name in order {
                let written = try Data(contentsOf: save.folder.appendingPathComponent(name))
                guard written == Data(files[name]!) else { throw AuroraError.invalidFormat("\(name) differs from what was written") }
            }
            reloaded = try SaveGame.load(from: save.folder, game: save.game, encoding: save.encoding, textLanguage: save.textLanguage)
        } catch {
            throw CommitError.verificationFailed(error.localizedDescription, rolledBack: rollback())
        }

        try? store.recordResult(of: version, for: save.folder)
        store.prune(save.folder, keeping: retention)
        return CommitResult(version: version, writtenFiles: order, reloaded: reloaded)
    }

    /// Parses an output file before anything is written.
    static func validate(_ name: String, _ bytes: [UInt8], save: SaveGame) throws {
        do {
            if name == save.fileNames.archive {
                let archive = try ERFArchive(bytes: bytes)
                guard let module = archive.data(for: save.moduleResRef, type: .sav) else {
                    throw SaveGameError.missingModule(save.moduleResRef)
                }
                let inner = try ERFArchive(bytes: module)
                guard let ifo = inner.data(for: "module", type: .ifo) else { throw SaveGameError.missingFile("Module.ifo") }
                _ = try GFFDocument(bytes: ifo)
                if let inventory = archive.data(for: "inventory", type: .res) { _ = try GFFDocument(bytes: inventory) }
            } else if name.lowercased().hasSuffix(".res") {
                _ = try GFFDocument(bytes: bytes)
            }
        } catch {
            throw CommitError.invalidOutput(name, error.localizedDescription)
        }
    }
}

/// The HMAC-SHA1 signatures the Xbox releases keep next to save files. Regenerated only
/// for saves that already carry .sig files, as KSE did.
enum XboxSignatures {
    static let sources = [("partytable.res", "SAVE_PARTY.sig"), ("globalvars.res", "SAVE_VARS.sig"),
                          ("savenfo.res", "SAVE_INFO.sig"), ("screen.tga", "Screen.sig")]

    static func hmac(_ bytes: [UInt8], key: [UInt8]) -> [UInt8] {
        Array(HMAC<Insecure.SHA1>.authenticationCode(for: bytes, using: SymmetricKey(data: key)))
    }

    static func signatures(for save: SaveGame, replacing pending: [String: [UInt8]]) -> [String: [UInt8]] {
        let folder = save.folder
        let present = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        func actualName(_ name: String) -> String? { present.first { $0.lowercased() == name.lowercased() } }
        func contents(_ name: String) -> [UInt8]? {
            if let pending = pending.first(where: { $0.key.lowercased() == name.lowercased() }) { return pending.value }
            return actualName(name).flatMap { try? Data(contentsOf: folder.appendingPathComponent($0)) }.map { [UInt8]($0) }
        }

        let key = save.game.signatureKey
        var result: [String: [UInt8]] = [:]
        for (source, signature) in sources {
            guard let data = contents(source) else { continue }
            result[actualName(signature) ?? signature] = hmac(data, key: key)
        }
        if let archive = contents("savegame.sav"), archive.count >= ERFArchive.headerSize {
            let reader = BinaryReader(archive)
            let entries = Int((try? reader.uint32(at: 16)) ?? 0)
            let resources = Int((try? reader.uint32(at: 28)) ?? 0)
            let split = min(archive.count, max(ERFArchive.headerSize, resources + 8 * entries))
            result[actualName("SAVE_HEADERVAR.sig") ?? "SAVE_HEADERVAR.sig"] = hmac(Array(archive[ERFArchive.headerSize ..< split]), key: key)
            result[actualName("SAVE_DATA.sig") ?? "SAVE_DATA.sig"] = hmac(Array(archive[split...]), key: key)
        }
        return result
    }
}
