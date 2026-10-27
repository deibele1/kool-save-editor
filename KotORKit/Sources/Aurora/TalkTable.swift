// KSEMac — a KotOR savegame editor for macOS.
// BioWare TLK V3.0 talk tables (dialog.tlk).
// Swift port of xoreos-tools' Aurora::TalkTable_TLK (https://github.com/xoreos/xoreos-tools).
// GNU GPL v3 or later.
//
// Differences from the C++ original: the file is memory mapped and entries are decoded
// on demand; V4 (Jade Empire/Witcher) and GFF-based talk tables are not supported.

import Foundation

public final class TalkTable: Sendable {
    public let languageID: UInt32
    public let count: Int
    public let encoding: TextEncoding
    private let data: Data
    private let stringsOffset: Int

    public static let headerSize = 20
    public static let entrySize = 40

    public convenience init(url: URL, encoding: TextEncoding? = nil) throws {
        try self.init(data: Data(contentsOf: url, options: .alwaysMapped), encoding: encoding)
    }

    public init(data: Data, encoding: TextEncoding? = nil) throws {
        let header = BinaryReader([UInt8](data.prefix(Self.headerSize)))
        guard try header.fixedString(at: 0, length: 4) == "TLK " else { throw AuroraError.invalidFormat("not a TLK file") }
        let version = try header.fixedString(at: 4, length: 4)
        guard version == "V3.0" else { throw AuroraError.unsupportedVersion("TLK \(version)") }
        languageID = try header.uint32(at: 8)
        let count = Int(try header.uint32(at: 12))
        stringsOffset = Int(try header.uint32(at: 16))
        guard count <= (data.count - Self.headerSize) / Self.entrySize else {
            throw AuroraError.invalidFormat("TLK entry table lies outside the file")
        }
        self.count = count
        self.data = data
        self.encoding = encoding ?? TextEncoding.forLanguage(languageID)
    }

    /// The text for a string reference, or nil when the reference is invalid or empty.
    public func string(_ strRef: UInt32) -> String? {
        guard strRef != GFFLocString.noStringRef, Int(strRef) < count else { return nil }
        let entry = Self.headerSize + Int(strRef) * Self.entrySize
        let offset = stringsOffset + Int(uint32(entry + 28))
        let length = Int(uint32(entry + 32))
        guard length > 0, offset >= 0, offset <= data.count, length <= data.count - offset else { return nil }
        let start = data.startIndex + offset
        return encoding.decode(data[start ..< start + length])
    }

    private func uint32(_ position: Int) -> UInt32 {
        let start = data.startIndex + position
        return UInt32(data[start]) | UInt32(data[start + 1]) << 8 | UInt32(data[start + 2]) << 16 | UInt32(data[start + 3]) << 24
    }
}
