// KSEMac — a KotOR savegame editor for macOS.
// Versioned snapshots of save folders, so every write can be rolled back.
//
// Snapshots live outside the game's saves folder (the game would list any extra folder
// there as a broken save), one directory per save keyed by its path, each with a
// manifest of file sizes and SHA-256 digests. On APFS the copies are clones and cost
// almost no space until the save changes.

import CryptoKit
import Foundation

public struct SaveVersion: Sendable, Hashable, Identifiable, Codable {
    public enum Reason: String, Codable, Sendable {
        case beforeSave
        case beforeRestore
        case manual
    }

    public struct File: Sendable, Hashable, Codable {
        public var name: String
        public var size: Int
        public var sha256: String
    }

    public var id: String
    public var date: Date
    public var reason: Reason
    /// The edits about to be saved (or what was about to be restored) when the snapshot was taken.
    public var summary: String
    public var saveName: String
    public var savePath: String
    public var files: [File]
    /// 1 for the original save, then counting up.
    public var number: Int?
    /// How this version differs from the one before it: "None" for the original, the edits
    /// saved, "Restored …", or "Changed outside the editor".
    public var changes: String?
    /// For snapshots taken before a restore: the number of the version that was restored.
    public var restoringNumber: Int?
    /// The save's files once the save or restore that followed this snapshot had completed.
    public var result: [File]?
    /// When the save's files were last written, as of the snapshot.
    public var modified: Date?
    /// The game's play time counter (savenfo.res TIMEPLAYED, seconds) as of the snapshot.
    public var timePlayed: Int?
    /// Labels written by an earlier build ("Original", "After: …"); read to derive `changes`.
    public var state: String?
    public var restoring: String?

    public static let noChanges = "None"
    public static let externalChanges = "Changed outside the editor"

    public var title: String { Self.title(number: number ?? 0) }
    public var isOriginal: Bool { number == 1 }
    public var savedDate: Date { modified ?? date }
    public var totalSize: Int { files.reduce(0) { $0 + $1.size } }

    static func title(number: Int) -> String { number == 1 ? "Original" : "Version \(number)" }

    /// What the save or restore that followed this snapshot changed.
    var outcome: String {
        guard reason == .beforeRestore else { return summary }
        if let restoringNumber { return "Restored \(Self.title(number: restoringNumber))" }
        return restoring == "Original" ? "Restored Original" : "Restored an earlier version"
    }
}

/// The save as it is now, described relative to its newest version.
public struct CurrentSaveState: Sendable, Hashable {
    /// How the save differs from the newest version.
    public var changes: String
    public var modified: Date?
    public var size: Int
    public var timePlayed: Int?
}

extension Array where Element == SaveVersion {
    /// Play time gained since the version before each one (oldest first input); nil for the
    /// first version or when either play time is unknown. Negative after restoring an older one.
    public func playTimeDeltas() -> [Int?] {
        indices.map { index in
            guard index > 0, let now = self[index].timePlayed, let before = self[index - 1].timePlayed else { return nil }
            return now - before
        }
    }
}

public enum SaveVersionError: Error, LocalizedError {
    case emptySave(URL)
    case damagedSnapshot(String)

    public var errorDescription: String? {
        switch self {
        case .emptySave(let url): "There are no save files to back up in \(url.lastPathComponent)."
        case .damagedSnapshot(let name): "The backup copy of \(name) is damaged."
        }
    }
}

public struct SaveVersionStore: Sendable {
    public let root: URL

    public init(root: URL = SaveVersionStore.defaultRoot) {
        self.root = root
    }

    public static var defaultRoot: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("KSEMac/Versions", isDirectory: true)
    }

    static let managedExtensions: Set<String> = ["res", "sav", "tga", "sig"]
    static let manifestName = "version.json"

    /// The directory holding every snapshot of one save folder.
    public func folder(for save: URL) -> URL {
        let path = save.standardizedFileURL.path
        let digest = SHA256.hash(data: Data(path.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        let parent = save.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
        let name = "\(parent) – \(save.lastPathComponent)".replacingOccurrences(of: "/", with: "-")
        return root.appendingPathComponent("\(name) [\(digest)]", isDirectory: true)
    }

    public func location(of version: SaveVersion, for save: URL) -> URL {
        folder(for: save).appendingPathComponent(version.id, isDirectory: true)
    }

    /// Snapshots of a save, newest first.
    public func versions(for save: URL) -> [SaveVersion] {
        let base = folder(for: save)
        let items = (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? []
        let decoder = Self.decoder()
        var versions = items.compactMap { item -> SaveVersion? in
            guard let data = try? Data(contentsOf: item.appendingPathComponent(Self.manifestName)) else { return nil }
            return try? decoder.decode(SaveVersion.self, from: data)
        }
        .sorted { ($0.date, $0.id) < ($1.date, $1.id) }

        // Versions from earlier builds: number them in order, and derive their changes from the
        // label they were written with, or else from the save that preceded them.
        for index in versions.indices {
            if versions[index].timePlayed == nil {
                versions[index].timePlayed = try? SaveSummary.read(folder: location(of: versions[index], for: save), game: .kotor1).timePlayed
            }
            if versions[index].number == nil {
                versions[index].number = index == 0 ? 1 : (versions[index - 1].number ?? index) + 1
            }
            if versions[index].changes == nil {
                if let state = versions[index].state {
                    versions[index].changes = state == "Original" ? SaveVersion.noChanges
                        : state.hasPrefix("After: ") ? String(state.dropFirst(7)) : state
                } else {
                    versions[index].changes = index == 0 ? SaveVersion.noChanges : versions[index - 1].outcome
                }
            }
        }
        return versions.reversed()
    }

    /// Describes the save as it is now. Nil before the first version exists.
    public func currentState(of save: URL) -> CurrentSaveState? {
        guard let newest = versions(for: save).first, let files = try? Self.records(in: save) else { return nil }
        let modified = (try? Self.saveFiles(in: save))?.compactMap { Self.modificationDate(save.appendingPathComponent($0)) }.max()
        let timePlayed = try? SaveSummary.read(folder: save, game: .kotor1).timePlayed
        return CurrentSaveState(changes: Self.changes(of: files, timePlayed: timePlayed, following: newest), modified: modified,
                                size: files.reduce(0) { $0 + $1.size }, timePlayed: timePlayed)
    }

    /// How a save holding `files` (with the game's play time counter at `timePlayed`) differs
    /// from the newest version before it.
    static func changes(of files: [SaveVersion.File], timePlayed: Int?, following previous: SaveVersion?) -> String {
        guard let previous else { return SaveVersion.noChanges }
        if let result = previous.result, sameFiles(files, result) { return previous.outcome }
        // Unchanged since the snapshot: the operation after it failed and was rolled back.
        if sameFiles(files, previous.files) { return SaveVersion.noChanges }
        // No recorded result (versions from before results were kept): assume it went through.
        guard previous.result != nil else { return previous.outcome }
        // The editor's change was followed by another: the game saving after play, if the play
        // time went up.
        if let now = timePlayed, let before = previous.timePlayed, now > before {
            return "\(previous.outcome), then played"
        }
        return "\(previous.outcome), then \(SaveVersion.externalChanges.lowercased())"
    }

    static func sameFiles(_ a: [SaveVersion.File], _ b: [SaveVersion.File]) -> Bool {
        func key(_ files: [SaveVersion.File]) -> [String: String] {
            Dictionary(files.map { ($0.name.lowercased(), $0.sha256) }, uniquingKeysWith: { first, _ in first })
        }
        return key(a) == key(b)
    }

    @discardableResult
    public func snapshot(_ save: URL, reason: SaveVersion.Reason, summary: String, restoring: Int? = nil) throws -> SaveVersion {
        let fm = FileManager.default
        let files = try Self.saveFiles(in: save)
        guard !files.isEmpty else { throw SaveVersionError.emptySave(save) }
        let previous = versions(for: save).first
        let modified = files.compactMap { Self.modificationDate(save.appendingPathComponent($0)) }.max()
        let info = try? SaveSummary.read(folder: save, game: .kotor1)

        let date = Date()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        var id = formatter.string(from: date)
        let base = folder(for: save)
        while fm.fileExists(atPath: base.appendingPathComponent(id).path) { id += "+" }
        let destination = base.appendingPathComponent(id, isDirectory: true)
        let staging = base.appendingPathComponent(".\(id).partial", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        do {
            var records: [SaveVersion.File] = []
            for name in files {
                let source = save.appendingPathComponent(name)
                let copy = staging.appendingPathComponent(name)
                try fm.copyItem(at: source, to: copy)
                let data = try Data(contentsOf: copy, options: .alwaysMapped)
                records.append(SaveVersion.File(name: name, size: data.count, sha256: Self.digest(data)))
            }
            let version = SaveVersion(id: id, date: date, reason: reason, summary: summary,
                                      saveName: info?.name ?? save.lastPathComponent,
                                      savePath: save.standardizedFileURL.path, files: records,
                                      number: (previous?.number ?? 0) + 1,
                                      changes: Self.changes(of: records, timePlayed: info?.timePlayed, following: previous),
                                      restoringNumber: restoring, result: nil, modified: modified,
                                      timePlayed: info?.timePlayed)
            try Self.encoder().encode(version).write(to: staging.appendingPathComponent(Self.manifestName))
            try fm.moveItem(at: staging, to: destination)
            return version
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    /// Records the save's files after the save or restore that followed `version`, so the next
    /// version can tell whether anything else (such as the game) changed the save in between.
    public func recordResult(of version: SaveVersion, for save: URL) throws {
        var updated = version
        updated.result = try Self.records(in: save)
        let manifest = location(of: version, for: save).appendingPathComponent(Self.manifestName)
        try Self.encoder().encode(updated).write(to: manifest, options: .atomic)
    }

    /// Restores a snapshot. The current state is snapshotted first (and the restore refused
    /// if that fails), so a restore can itself be undone; that snapshot is returned.
    @discardableResult
    public func restore(_ version: SaveVersion, to save: URL) throws -> SaveVersion {
        try verify(version, for: save)
        let current = try snapshot(save, reason: .beforeRestore, summary: "Before restoring \(version.title)", restoring: version.number)
        try restoreFiles(of: version, to: save)
        try? recordResult(of: current, for: save)
        return current
    }

    /// Checks a snapshot's files against its manifest.
    public func verify(_ version: SaveVersion, for save: URL) throws {
        let base = location(of: version, for: save)
        for file in version.files {
            guard let data = try? Data(contentsOf: base.appendingPathComponent(file.name), options: .alwaysMapped),
                  data.count == file.size, Self.digest(data) == file.sha256 else {
                throw SaveVersionError.damagedSnapshot(file.name)
            }
        }
    }

    /// Makes the save's files identical to the snapshot without taking a new snapshot.
    func restoreFiles(of version: SaveVersion, to save: URL) throws {
        let fm = FileManager.default
        let base = location(of: version, for: save)
        for file in version.files {
            try Self.replace(save.appendingPathComponent(file.name), withContentsOf: base.appendingPathComponent(file.name))
        }
        let kept = Set(version.files.map { $0.name.lowercased() })
        for name in try Self.saveFiles(in: save) where !kept.contains(name.lowercased()) {
            try fm.removeItem(at: save.appendingPathComponent(name))
        }
    }

    public func delete(_ version: SaveVersion, for save: URL) throws {
        try FileManager.default.removeItem(at: location(of: version, for: save))
    }

    /// Keeps the original and the newest `limit` snapshots of a save.
    public func prune(_ save: URL, keeping limit: Int) {
        let all = versions(for: save)
        let kept = Set(all.prefix(max(1, limit)).map(\.id) + all.filter(\.isOriginal).map(\.id))
        for version in all where !kept.contains(version.id) {
            try? delete(version, for: save)
        }
    }

    // MARK: Helpers

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(dateFormatter().string(from: date))
        }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = dateFormatter().date(from: text) ?? ISO8601DateFormatter().date(from: text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad date \(text)"))
            }
            return date
        }
        return decoder
    }

    static func dateFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    /// Names, sizes and digests of the save's files as they are now.
    static func records(in save: URL) throws -> [SaveVersion.File] {
        try saveFiles(in: save).map { name in
            let data = try Data(contentsOf: save.appendingPathComponent(name), options: .alwaysMapped)
            return SaveVersion.File(name: name, size: data.count, sha256: digest(data))
        }
    }

    static func modificationDate(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    static func saveFiles(in save: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: save.path)
            .filter { !$0.hasPrefix(".") && managedExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
            .sorted()
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Replaces `destination` atomically with a copy of `source` (same-volume rename).
    static func replace(_ destination: URL, withContentsOf source: URL) throws {
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".kse-\(UUID().uuidString).tmp")
        try FileManager.default.copyItem(at: source, to: temporary)
        try commitTemporary(temporary, to: destination)
    }

    static func write(_ data: Data, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".kse-\(UUID().uuidString).tmp")
        try data.write(to: temporary)
        try commitTemporary(temporary, to: destination)
    }

    private static func commitTemporary(_ temporary: URL, to destination: URL) throws {
        if Foundation.rename(temporary.path, destination.path) != 0 {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }
}
