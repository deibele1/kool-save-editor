// KSEMac — a KotOR savegame editor for macOS.
// BioWare KEY V1 indexes and BIF V1 archives (chitin.key + data/*.bif).
// Swift port of xoreos-tools' Aurora::KEYFile and Aurora::BIFFile
// (https://github.com/xoreos/xoreos-tools). GNU GPL v3 or later.
//
// Differences from the C++ original: BIF files are memory mapped and read lazily,
// tables are bounds-checked, and BIF paths are resolved case-insensitively so
// `data\2da.bif` finds `Data/2DA.bif` on case-sensitive volumes. KEY/BIF V1.1 (NWN2)
// and fixed BIF resources are not supported.

import Foundation

public struct KeyFile: Sendable {
    public struct Entry: Sendable {
        public let resRef: String
        public let type: ResourceType
        public let bifIndex: Int
        public let resourceIndex: Int
    }

    public let bifPaths: [String]
    public let entries: [Entry]
    private let lookup: [String: Int]

    public init(bytes: [UInt8]) throws {
        var reader = BinaryReader(bytes)
        guard try reader.readTag() == "KEY " else { throw AuroraError.invalidFormat("not a KEY file") }
        let version = try reader.readTag()
        guard version == "V1  " else { throw AuroraError.unsupportedVersion("KEY \(version)") }

        let bifCount = Int(try reader.readUInt32())
        let entryCount = Int(try reader.readUInt32())
        let fileTableOffset = Int(try reader.readUInt32())
        let keyTableOffset = Int(try reader.readUInt32())
        guard bifCount <= (bytes.count - min(bytes.count, fileTableOffset)) / 12,
              entryCount <= (bytes.count - min(bytes.count, keyTableOffset)) / 22 else {
            throw AuroraError.invalidFormat("KEY tables lie outside the file")
        }

        var paths: [String] = []
        for i in 0 ..< bifCount {
            let at = fileTableOffset + i * 12
            let nameOffset = Int(try reader.uint32(at: at + 4))
            let nameSize = Int(try reader.uint16(at: at + 8))
            var path = try reader.fixedString(at: nameOffset, length: nameSize).replacingOccurrences(of: "\\", with: "/")
            while path.hasPrefix("/") { path.removeFirst() }
            paths.append(path)
        }

        var entries: [Entry] = []
        var lookup: [String: Int] = [:]
        entries.reserveCapacity(entryCount)
        for i in 0 ..< entryCount {
            let at = keyTableOffset + i * 22
            let resRef = try reader.fixedString(at: at, length: 16).lowercased()
            let type = ResourceType(rawValue: try reader.uint16(at: at + 16))
            let id = try reader.uint32(at: at + 18)
            let entry = Entry(resRef: resRef, type: type, bifIndex: Int(id >> 20), resourceIndex: Int(id & 0xFFFFF))
            if lookup[Self.key(resRef, type)] == nil { lookup[Self.key(resRef, type)] = entries.count }
            entries.append(entry)
        }
        bifPaths = paths
        self.entries = entries
        self.lookup = lookup
    }

    private static func key(_ resRef: String, _ type: ResourceType) -> String {
        "\(resRef.lowercased()).\(type.rawValue)"
    }

    public func entry(_ resRef: String, _ type: ResourceType) -> Entry? {
        lookup[Self.key(resRef, type)].map { entries[$0] }
    }
}

public struct BIFFile: Sendable {
    private struct Slot: Sendable { var offset: Int; var size: Int }

    private let data: Data
    private let slots: [Slot]

    public init(url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .alwaysMapped))
    }

    public init(data: Data) throws {
        let header = BinaryReader([UInt8](data.prefix(20)))
        guard try header.fixedString(at: 0, length: 4) == "BIFF" else { throw AuroraError.invalidFormat("not a BIF file") }
        let version = try header.fixedString(at: 4, length: 4)
        guard version == "V1  " else { throw AuroraError.unsupportedVersion("BIF \(version)") }
        let count = Int(try header.uint32(at: 8))
        let tableOffset = Int(try header.uint32(at: 16))
        guard tableOffset <= data.count, count <= (data.count - tableOffset) / 16 else {
            throw AuroraError.invalidFormat("BIF table lies outside the file")
        }
        let table = BinaryReader([UInt8](data[data.startIndex + tableOffset ..< data.startIndex + tableOffset + count * 16]))
        var slots: [Slot] = []
        slots.reserveCapacity(count)
        for i in 0 ..< count {
            slots.append(Slot(offset: Int(try table.uint32(at: i * 16 + 4)), size: Int(try table.uint32(at: i * 16 + 8))))
        }
        self.data = data
        self.slots = slots
    }

    public var count: Int { slots.count }

    public func resource(at index: Int) throws -> [UInt8] {
        guard index >= 0, index < slots.count else { throw AuroraError.notFound("BIF resource \(index)") }
        let slot = slots[index]
        guard slot.offset <= data.count, slot.size <= data.count - slot.offset else {
            throw AuroraError.invalidFormat("BIF resource lies outside the file")
        }
        let start = data.startIndex + slot.offset
        return [UInt8](data[start ..< start + slot.size])
    }
}

/// The game's base resources: `chitin.key` and the BIF files it references.
public final class KeyArchive: @unchecked Sendable {
    public let root: URL
    public let key: KeyFile
    private var bifs: [Int: BIFFile] = [:]
    private let lock = NSLock()

    public init(root: URL) throws {
        guard let keyURL = FileManager.default.caseInsensitiveItem(named: "chitin.key", in: root) else {
            throw AuroraError.notFound("chitin.key in \(root.path)")
        }
        self.root = root
        key = try KeyFile(bytes: [UInt8](Data(contentsOf: keyURL, options: .alwaysMapped)))
    }

    public func contains(_ resRef: String, _ type: ResourceType) -> Bool {
        key.entry(resRef, type) != nil
    }

    public func resource(_ resRef: String, _ type: ResourceType) throws -> [UInt8]? {
        guard let entry = key.entry(resRef, type) else { return nil }
        return try bif(entry.bifIndex).resource(at: entry.resourceIndex)
    }

    public func entries(of type: ResourceType) -> [KeyFile.Entry] {
        key.entries.filter { $0.type == type }
    }

    private func bif(_ index: Int) throws -> BIFFile {
        lock.lock()
        defer { lock.unlock() }
        if let cached = bifs[index] { return cached }
        guard index < key.bifPaths.count else { throw AuroraError.notFound("BIF #\(index)") }
        guard let url = FileManager.default.caseInsensitiveItem(path: key.bifPaths[index], in: root) else {
            throw AuroraError.notFound(key.bifPaths[index])
        }
        let bif = try BIFFile(url: url)
        bifs[index] = bif
        return bif
    }
}

extension FileManager {
    /// Finds `name` in `directory` ignoring case.
    public func caseInsensitiveItem(named name: String, in directory: URL) -> URL? {
        let direct = directory.appendingPathComponent(name)
        if fileExists(atPath: direct.path) { return direct }
        let wanted = name.lowercased()
        guard let items = try? contentsOfDirectory(atPath: directory.path) else { return nil }
        return items.first { $0.lowercased() == wanted }.map { directory.appendingPathComponent($0) }
    }

    /// Resolves a relative `/`-separated path ignoring the case of each component.
    public func caseInsensitiveItem(path: String, in directory: URL) -> URL? {
        var current = directory
        for component in path.split(separator: "/") where !component.isEmpty {
            guard let next = caseInsensitiveItem(named: String(component), in: current) else { return nil }
            current = next
        }
        return current
    }
}
