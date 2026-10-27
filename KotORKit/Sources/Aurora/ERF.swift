// KSEMac — a KotOR savegame editor for macOS.
// BioWare ERF V1.0 archives (ERF, MOD, SAV, HAK): reader and writer.
// Swift port of xoreos-tools' Aurora::ERFFile and Aurora::ERFWriter
// (https://github.com/xoreos/xoreos-tools). GNU GPL v3 or later.
//
// Differences from the C++ original:
// - Rewriting preserves the archive's header (type, build date, description, reserved
//   bytes) and every resource ID, as KSE did, instead of stamping a new header.
// - Key and resource tables are validated against the file size.
// - Dragon Age (V2.x/V3.0), NWN2 (V1.1), encryption and compression are not supported.

import Foundation

public struct ERFArchive: Equatable, Sendable {
    public struct Resource: Equatable, Sendable {
        public var resRef: String
        public var type: ResourceType
        public var resID: UInt32
        public var data: [UInt8]

        public init(resRef: String, type: ResourceType, resID: UInt32, data: [UInt8]) {
            self.resRef = resRef
            self.type = type
            self.resID = resID
            self.data = data
        }

        public var fileName: String { "\(resRef).\(type.fileExtension)" }
    }

    public struct LocalizedString: Equatable, Sendable {
        public var languageID: UInt32
        public var bytes: [UInt8]

        public init(languageID: UInt32, bytes: [UInt8]) {
            self.languageID = languageID
            self.bytes = bytes
        }
    }

    public var fileType: String
    public var version: String
    public var buildYear: UInt32
    public var buildDay: UInt32
    public var descriptionStrRef: UInt32
    public var localizedStrings: [LocalizedString]
    public var reserved: [UInt8]
    public var resources: [Resource]

    public static let headerSize = 160

    public init(fileType: String = "ERF ", resources: [Resource] = []) {
        let now = Calendar(identifier: .gregorian).dateComponents([.year], from: Date())
        self.fileType = fileType
        version = "V1.0"
        buildYear = UInt32(max(0, (now.year ?? 1900) - 1900))
        buildDay = UInt32(max(0, (Calendar(identifier: .gregorian).ordinality(of: .day, in: .year, for: Date()) ?? 1) - 1))
        descriptionStrRef = 0
        localizedStrings = []
        reserved = Array(repeating: 0, count: 116)
        self.resources = resources
    }

    public init(bytes: [UInt8]) throws {
        var reader = BinaryReader(bytes)
        fileType = try reader.readTag()
        version = try reader.readTag()
        guard ["ERF ", "MOD ", "SAV ", "HAK "].contains(fileType) else {
            throw AuroraError.invalidFormat("not an ERF archive (\(fileType))")
        }
        guard version == "V1.0" else { throw AuroraError.unsupportedVersion("ERF \(version)") }

        let languageCount = Int(try reader.readUInt32())
        let localizedSize = Int(try reader.readUInt32())
        let entryCount = Int(try reader.readUInt32())
        let localizedOffset = Int(try reader.readUInt32())
        let keyOffset = Int(try reader.readUInt32())
        let resourceOffset = Int(try reader.readUInt32())
        buildYear = try reader.readUInt32()
        buildDay = try reader.readUInt32()
        descriptionStrRef = try reader.readUInt32()
        reserved = try reader.readBytes(116)

        guard entryCount <= (bytes.count - min(bytes.count, keyOffset)) / 24,
              entryCount <= (bytes.count - min(bytes.count, resourceOffset)) / 8 else {
            throw AuroraError.invalidFormat("ERF tables lie outside the file")
        }

        localizedStrings = []
        if languageCount > 0 {
            guard localizedOffset <= bytes.count, localizedSize <= bytes.count - localizedOffset else {
                throw AuroraError.invalidFormat("ERF description lies outside the file")
            }
            var cursor = localizedOffset
            for _ in 0 ..< languageCount {
                let languageID = try reader.uint32(at: cursor)
                let length = Int(try reader.uint32(at: cursor + 4))
                localizedStrings.append(LocalizedString(languageID: languageID,
                                                        bytes: try reader.bytes(at: cursor + 8, count: length)))
                cursor += 8 + length
            }
        }

        resources = []
        resources.reserveCapacity(entryCount)
        for i in 0 ..< entryCount {
            let key = keyOffset + i * 24
            let resRef = try reader.fixedString(at: key, length: 16)
            let resID = try reader.uint32(at: key + 16)
            let type = ResourceType(rawValue: try reader.uint16(at: key + 20))
            let offset = Int(try reader.uint32(at: resourceOffset + i * 8))
            let size = Int(try reader.uint32(at: resourceOffset + i * 8 + 4))
            guard offset <= bytes.count, size <= bytes.count - offset else {
                throw AuroraError.invalidFormat("ERF resource \(resRef) lies outside the file")
            }
            resources.append(Resource(resRef: resRef, type: type, resID: resID,
                                      data: Array(bytes[offset ..< offset + size])))
        }
    }

    public init(data: Data) throws {
        try self.init(bytes: [UInt8](data))
    }

    public func encoded() -> [UInt8] {
        let localizedSize = localizedStrings.reduce(0) { $0 + 8 + $1.bytes.count }
        let keyOffset = Self.headerSize + localizedSize
        let resourceOffset = keyOffset + resources.count * 24
        var dataOffset = resourceOffset + resources.count * 8
        let total = dataOffset + resources.reduce(0) { $0 + $1.data.count }

        var out = BinaryWriter(capacity: total)
        out.writeTag(fileType)
        out.writeTag(version)
        out.write(UInt32(localizedStrings.count))
        out.write(UInt32(localizedSize))
        out.write(UInt32(resources.count))
        out.write(UInt32(Self.headerSize))
        out.write(UInt32(keyOffset))
        out.write(UInt32(resourceOffset))
        out.write(buildYear)
        out.write(buildDay)
        out.write(descriptionStrRef)
        out.writeFixed(reserved, length: 116)

        for string in localizedStrings {
            out.write(string.languageID)
            out.write(UInt32(string.bytes.count))
            out.write(contentsOf: string.bytes)
        }
        for resource in resources {
            out.writeFixed(Array(resource.resRef.utf8), length: 16)
            out.write(resource.resID)
            out.write(resource.type.rawValue)
            out.write(UInt16(0))
        }
        for resource in resources {
            out.write(UInt32(dataOffset))
            out.write(UInt32(resource.data.count))
            dataOffset += resource.data.count
        }
        for resource in resources {
            out.write(contentsOf: resource.data)
        }
        return out.bytes
    }

    /// Case-insensitive lookup, as the game performs.
    public func index(of resRef: String, type: ResourceType) -> Int? {
        let wanted = resRef.lowercased()
        return resources.firstIndex { $0.type == type && $0.resRef.lowercased() == wanted }
    }

    public func data(for resRef: String, type: ResourceType) -> [UInt8]? {
        index(of: resRef, type: type).map { resources[$0].data }
    }

    /// Replaces a resource's data, or appends a new resource with the next free ID.
    public mutating func setData(_ data: [UInt8], for resRef: String, type: ResourceType) {
        if let i = index(of: resRef, type: type) {
            resources[i].data = data
        } else {
            let nextID = (resources.map(\.resID).max() ?? UInt32.max) &+ 1
            resources.append(Resource(resRef: resRef, type: type, resID: nextID, data: data))
        }
    }
}

/// Read-only, memory-mapped access to a large ERF such as a texture pack.
public struct ERFIndex: Sendable {
    private let data: Data
    private let slots: [String: (offset: Int, size: Int)]

    public init(url: URL) throws {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        let header = BinaryReader([UInt8](data.prefix(ERFArchive.headerSize)))
        guard ["ERF ", "MOD ", "SAV ", "HAK "].contains(try header.fixedString(at: 0, length: 4)) else {
            throw AuroraError.invalidFormat("not an ERF archive")
        }
        let count = Int(try header.uint32(at: 16))
        let keyOffset = Int(try header.uint32(at: 24))
        let resourceOffset = Int(try header.uint32(at: 28))
        guard keyOffset <= data.count, count <= (data.count - keyOffset) / 24,
              resourceOffset <= data.count, count <= (data.count - resourceOffset) / 8 else {
            throw AuroraError.invalidFormat("ERF tables lie outside the file")
        }
        let keys = BinaryReader([UInt8](data[data.startIndex + keyOffset ..< data.startIndex + keyOffset + count * 24]))
        let table = BinaryReader([UInt8](data[data.startIndex + resourceOffset ..< data.startIndex + resourceOffset + count * 8]))
        var slots: [String: (offset: Int, size: Int)] = [:]
        for i in 0 ..< count {
            let resRef = try keys.fixedString(at: i * 24, length: 16).lowercased()
            let type = try keys.uint16(at: i * 24 + 20)
            slots["\(resRef).\(type)"] = (Int(try table.uint32(at: i * 8)), Int(try table.uint32(at: i * 8 + 4)))
        }
        self.data = data
        self.slots = slots
    }

    public func data(for resRef: String, type: ResourceType) -> [UInt8]? {
        guard let slot = slots["\(resRef.lowercased()).\(type.rawValue)"], slot.offset <= data.count,
              slot.size <= data.count - slot.offset else { return nil }
        let start = data.startIndex + slot.offset
        return [UInt8](data[start ..< start + slot.size])
    }
}
