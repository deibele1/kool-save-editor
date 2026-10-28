// KSEMac — a KotOR savegame editor for macOS.
// BioWare RIM V1.0 archives: the level files in Modules/ (and KotOR's rims/), read-only.
// Swift port of xoreos-tools' Aurora::RIMFile (https://github.com/xoreos/xoreos-tools).
// GNU GPL v3 or later.
//
// Differences from the C++ original: the file is memory mapped and resources are read on
// demand, and the resource table is validated against the file size.

import Foundation

public struct RIMIndex: ArchiveIndex {
    public let entries: [ArchiveEntry]
    private let data: Data
    private let slots: [String: (offset: Int, size: Int)]

    public init(url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .alwaysMapped))
    }

    public init(data: Data) throws {
        let header = BinaryReader([UInt8](data.prefix(20)))
        guard try header.fixedString(at: 0, length: 4) == "RIM " else { throw AuroraError.invalidFormat("not a RIM archive") }
        let version = try header.fixedString(at: 4, length: 4)
        guard version == "V1.0" else { throw AuroraError.unsupportedVersion("RIM \(version)") }
        // A reserved word precedes the resource count and the offset of the resource table.
        let count = Int(try header.uint32(at: 12))
        let tableOffset = Int(try header.uint32(at: 16))
        guard tableOffset <= data.count, count <= (data.count - tableOffset) / 32 else {
            throw AuroraError.invalidFormat("RIM resource table lies outside the file")
        }
        // Each entry: name (16), type (16 bits, then 16 reserved), resource ID, offset, size.
        let table = BinaryReader([UInt8](data[data.startIndex + tableOffset ..< data.startIndex + tableOffset + count * 32]))
        var entries: [ArchiveEntry] = []
        var slots: [String: (offset: Int, size: Int)] = [:]
        for i in 0 ..< count {
            let resRef = try table.fixedString(at: i * 32, length: 16).lowercased()
            let type = try table.uint16(at: i * 32 + 16)
            entries.append(ArchiveEntry(resRef: resRef, type: ResourceType(rawValue: type)))
            slots["\(resRef).\(type)"] = (Int(try table.uint32(at: i * 32 + 24)), Int(try table.uint32(at: i * 32 + 28)))
        }
        self.entries = entries
        self.data = data
        self.slots = slots
    }

    public func data(for resRef: String, type: ResourceType) -> [UInt8]? {
        mappedSlice(data, slots["\(resRef.lowercased()).\(type.rawValue)"])
    }
}
