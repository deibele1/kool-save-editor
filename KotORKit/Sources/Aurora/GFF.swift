// KSEMac — a KotOR savegame editor for macOS.
// BioWare GFF V3.2 ("generic file format") model, reader and writer.
// Swift port of xoreos-tools' Aurora::GFF3File and Aurora::GFF3Writer
// (https://github.com/xoreos/xoreos-tools). GNU GPL v3 or later.
//
// Differences from the C++ original:
// - Values are kept bit-exact (floats, string bytes) so unedited data round trips.
// - Section bounds, field/label/struct indices and recursion depth are validated
//   (the original checked `index > count` and offsets only).
// - Strings are stored as raw bytes and decoded with the game's code page instead of
//   being forced through ASCII.
// - The writer does not de-duplicate field data (an O(n²) scan in the original) and
//   writes empty structs with the 0xFFFFFFFF field index BioWare and KSE use.
// - NWN premium-module repair, V3.3 and Witcher StrRef fields are not supported.

import Foundation

public enum GFFFieldType: UInt32, Sendable, CaseIterable {
    case byte = 0, char, word, short, dword, int, dword64, int64, float, double
    case exoString, resRef, locString, void, structure, list, orientation, vector
}

/// A CExoLocString: a talk table reference plus optional inline strings, keyed by
/// `language * 2 + gender`.
public struct GFFLocString: Hashable, Sendable {
    public static let noStringRef: UInt32 = 0xFFFF_FFFF

    public struct Substring: Hashable, Sendable {
        public var languageID: UInt32
        public var bytes: [UInt8]

        public init(languageID: UInt32, bytes: [UInt8]) {
            self.languageID = languageID
            self.bytes = bytes
        }
    }

    public var stringRef: UInt32
    public var substrings: [Substring]

    public init(stringRef: UInt32 = GFFLocString.noStringRef, substrings: [Substring] = []) {
        self.stringRef = stringRef
        self.substrings = substrings
    }

    public var hasStringRef: Bool { stringRef != Self.noStringRef }

    /// The inline text, preferring `languageID` when several substrings exist.
    public func text(encoding: TextEncoding, languageID: UInt32? = nil) -> String? {
        let match = substrings.first { $0.languageID == languageID } ?? substrings.first
        return match.map { encoding.decode($0.bytes) }
    }

    /// Replaces the string with inline text, dropping the talk table reference the way
    /// the game does for player-entered names.
    public mutating func setText(_ text: String, encoding: TextEncoding, languageID: UInt32) {
        let bytes = encoding.encode(text)
        stringRef = Self.noStringRef
        if let index = substrings.firstIndex(where: { $0.languageID == languageID }) {
            substrings[index].bytes = bytes
        } else if substrings.count == 1 {
            substrings[0].bytes = bytes
        } else {
            substrings = [Substring(languageID: languageID, bytes: bytes)]
        }
    }
}

public enum GFFValue: Equatable, Sendable {
    case byte(UInt8)
    case char(Int8)
    case word(UInt16)
    case short(Int16)
    case dword(UInt32)
    case int(Int32)
    case dword64(UInt64)
    case int64(Int64)
    case float(Float)
    case double(Double)
    case exoString([UInt8])
    case resRef([UInt8])
    case locString(GFFLocString)
    case void([UInt8])
    case structure(GFFStruct)
    case list([GFFStruct])
    case orientation(Float, Float, Float, Float)
    case vector(Float, Float, Float)

    public var type: GFFFieldType {
        switch self {
        case .byte: .byte
        case .char: .char
        case .word: .word
        case .short: .short
        case .dword: .dword
        case .int: .int
        case .dword64: .dword64
        case .int64: .int64
        case .float: .float
        case .double: .double
        case .exoString: .exoString
        case .resRef: .resRef
        case .locString: .locString
        case .void: .void
        case .structure: .structure
        case .list: .list
        case .orientation: .orientation
        case .vector: .vector
        }
    }

    /// The value of an integer field.
    public var integer: Int? {
        switch self {
        case .byte(let v): Int(v)
        case .char(let v): Int(v)
        case .word(let v): Int(v)
        case .short(let v): Int(v)
        case .dword(let v): Int(v)
        case .int(let v): Int(v)
        case .dword64(let v): Int(exactly: v)
        case .int64(let v): Int(v)
        default: nil
        }
    }

    /// An integer value of the given type, clamped to the type's range.
    public static func integer(_ value: Int, as type: GFFFieldType) -> GFFValue? {
        func clamp<T: FixedWidthInteger>(_: T.Type) -> T { T(clamping: value) }
        switch type {
        case .byte: return .byte(clamp(UInt8.self))
        case .char: return .char(clamp(Int8.self))
        case .word: return .word(clamp(UInt16.self))
        case .short: return .short(clamp(Int16.self))
        case .dword: return .dword(clamp(UInt32.self))
        case .int: return .int(clamp(Int32.self))
        case .dword64: return .dword64(clamp(UInt64.self))
        case .int64: return .int64(clamp(Int64.self))
        default: return nil
        }
    }

    /// Values are equal when they would be written identically: floating-point values compare
    /// by bit pattern, so NaN garbage found in real saves equals itself and -0 differs from 0.
    public static func == (lhs: GFFValue, rhs: GFFValue) -> Bool {
        switch (lhs, rhs) {
        case let (.byte(a), .byte(b)): a == b
        case let (.char(a), .char(b)): a == b
        case let (.word(a), .word(b)): a == b
        case let (.short(a), .short(b)): a == b
        case let (.dword(a), .dword(b)): a == b
        case let (.int(a), .int(b)): a == b
        case let (.dword64(a), .dword64(b)): a == b
        case let (.int64(a), .int64(b)): a == b
        case let (.float(a), .float(b)): a.bitPattern == b.bitPattern
        case let (.double(a), .double(b)): a.bitPattern == b.bitPattern
        case let (.exoString(a), .exoString(b)): a == b
        case let (.resRef(a), .resRef(b)): a == b
        case let (.locString(a), .locString(b)): a == b
        case let (.void(a), .void(b)): a == b
        case let (.structure(a), .structure(b)): a == b
        case let (.list(a), .list(b)): a == b
        case let (.orientation(a1, b1, c1, d1), .orientation(a2, b2, c2, d2)):
            [a1, b1, c1, d1].map(\.bitPattern) == [a2, b2, c2, d2].map(\.bitPattern)
        case let (.vector(a1, b1, c1), .vector(a2, b2, c2)):
            [a1, b1, c1].map(\.bitPattern) == [a2, b2, c2].map(\.bitPattern)
        default: false
        }
    }

    public static func string(_ text: String, encoding: TextEncoding = .windows1252) -> GFFValue {
        .exoString(encoding.encode(text))
    }

    public static func resRef(_ text: String) -> GFFValue {
        .resRef(Array(text.utf8.prefix(16)))
    }
}

public struct GFFField: Equatable, Sendable {
    public var label: String
    public var value: GFFValue

    public init(label: String, value: GFFValue) {
        self.label = label
        self.value = value
    }
}

public struct GFFStruct: Equatable, Sendable {
    public var id: UInt32
    public var fields: [GFFField]

    public init(id: UInt32 = 0, fields: [GFFField] = []) {
        self.id = id
        self.fields = fields
    }

    public func index(of label: String) -> Int? {
        fields.firstIndex { $0.label == label }
    }

    public func has(_ label: String) -> Bool {
        index(of: label) != nil
    }

    /// Reads, replaces (keeping the field's position), appends or (with `nil`) removes a field.
    public subscript(label: String) -> GFFValue? {
        get { index(of: label).map { fields[$0].value } }
        set {
            if let i = index(of: label) {
                if let newValue { fields[i].value = newValue } else { fields.remove(at: i) }
            } else if let newValue {
                fields.append(GFFField(label: label, value: newValue))
            }
        }
    }

    public func integer(_ label: String) -> Int? {
        self[label]?.integer
    }

    /// Stores an integer, keeping the existing field's type (clamping to its range) or
    /// creating the field with `type`.
    public mutating func setInteger(_ label: String, _ value: Int, type: GFFFieldType = .int) {
        let existing = self[label]?.type
        let target = existing.flatMap { GFFValue.integer(0, as: $0) == nil ? nil : $0 } ?? type
        self[label] = GFFValue.integer(value, as: target)
    }

    public func float(_ label: String) -> Float? {
        if case .float(let v)? = self[label] { return v }
        return nil
    }

    public func string(_ label: String, encoding: TextEncoding = .windows1252) -> String? {
        switch self[label] {
        case .exoString(let raw)?, .resRef(let raw)?: encoding.decode(raw)
        default: nil
        }
    }

    public mutating func setString(_ label: String, _ text: String, encoding: TextEncoding = .windows1252) {
        if case .resRef? = self[label] {
            self[label] = .resRef(text)
        } else {
            self[label] = .string(text, encoding: encoding)
        }
    }

    public func locString(_ label: String) -> GFFLocString? {
        if case .locString(let v)? = self[label] { return v }
        return nil
    }

    public func structure(_ label: String) -> GFFStruct? {
        if case .structure(let v)? = self[label] { return v }
        return nil
    }

    public func list(_ label: String) -> [GFFStruct]? {
        if case .list(let v)? = self[label] { return v }
        return nil
    }

    public func void(_ label: String) -> [UInt8]? {
        if case .void(let v)? = self[label] { return v }
        return nil
    }

    /// Mutates a list field in place. Returns false when the field is missing (and
    /// `create` is false) or is not a list.
    @discardableResult
    public mutating func updateList(_ label: String, create: Bool = false, _ body: (inout [GFFStruct]) throws -> Void) rethrows -> Bool {
        guard let i = index(of: label) else {
            guard create else { return false }
            var list: [GFFStruct] = []
            try body(&list)
            fields.append(GFFField(label: label, value: .list(list)))
            return true
        }
        guard case .list(var list) = fields[i].value else { return false }
        fields[i].value = .list([])
        defer { fields[i].value = .list(list) }
        try body(&list)
        return true
    }

    /// Mutates a struct field in place. Returns false when it is missing or not a struct.
    @discardableResult
    public mutating func updateStruct(_ label: String, _ body: (inout GFFStruct) throws -> Void) rethrows -> Bool {
        guard let i = index(of: label), case .structure(var child) = fields[i].value else { return false }
        fields[i].value = .structure(GFFStruct())
        defer { fields[i].value = .structure(child) }
        try body(&child)
        return true
    }
}

public struct GFFDocument: Equatable, Sendable {
    public var fileType: String
    public var version: String
    public var root: GFFStruct

    public init(fileType: String, version: String = "V3.2", root: GFFStruct = GFFStruct(id: 0xFFFF_FFFF)) {
        self.fileType = fileType
        self.version = version
        self.root = root
    }

    public init(bytes: [UInt8]) throws {
        var reader = GFFReader(bytes: bytes)
        self = try reader.read()
    }

    public init(data: Data) throws {
        try self.init(bytes: [UInt8](data))
    }

    public func encoded() -> [UInt8] {
        GFFEncoder().encode(self)
    }
}

// MARK: - Reading

private struct GFFReader {
    private struct RawStruct { var id: UInt32; var data: UInt32; var fieldCount: UInt32 }
    private struct RawField { var type: UInt32; var label: UInt32; var data: UInt32 }
    private struct Section { var offset: Int; var count: Int }

    static let maxDepth = 256

    let reader: BinaryReader
    private var structs: [RawStruct] = []
    private var fields: [RawField] = []
    private var labels: [String] = []
    private var fieldData = Section(offset: 0, count: 0)
    private var fieldIndices = Section(offset: 0, count: 0)
    private var listIndices = Section(offset: 0, count: 0)

    init(bytes: [UInt8]) {
        reader = BinaryReader(bytes)
    }

    mutating func read() throws -> GFFDocument {
        var header = reader
        let fileType = try header.readTag()
        let version = try header.readTag()
        guard version == "V3.2" else { throw AuroraError.unsupportedVersion("GFF \(version)") }

        var raw: [Int] = []
        for _ in 0 ..< 12 { raw.append(Int(try header.readUInt32())) }

        func section(_ offset: Int, _ count: Int, elementSize: Int, _ name: String) throws -> Section {
            let length = count.multipliedReportingOverflow(by: elementSize)
            guard !length.overflow, offset >= 56 || count == 0, offset <= reader.count, length.partialValue <= reader.count - offset else {
                throw AuroraError.invalidFormat("GFF \(name) section lies outside the file")
            }
            return Section(offset: offset, count: count)
        }

        let structSection = try section(raw[0], raw[1], elementSize: 12, "struct")
        let fieldSection = try section(raw[2], raw[3], elementSize: 12, "field")
        let labelSection = try section(raw[4], raw[5], elementSize: 16, "label")
        fieldData = try section(raw[6], raw[7], elementSize: 1, "field data")
        fieldIndices = try section(raw[8], raw[9], elementSize: 1, "field indices")
        listIndices = try section(raw[10], raw[11], elementSize: 1, "list indices")
        guard structSection.count > 0 else { throw AuroraError.invalidFormat("GFF has no top-level struct") }

        structs.reserveCapacity(structSection.count)
        for i in 0 ..< structSection.count {
            let at = structSection.offset + i * 12
            structs.append(RawStruct(id: try reader.uint32(at: at), data: try reader.uint32(at: at + 4),
                                     fieldCount: try reader.uint32(at: at + 8)))
        }
        fields.reserveCapacity(fieldSection.count)
        for i in 0 ..< fieldSection.count {
            let at = fieldSection.offset + i * 12
            fields.append(RawField(type: try reader.uint32(at: at), label: try reader.uint32(at: at + 4),
                                   data: try reader.uint32(at: at + 8)))
        }
        labels.reserveCapacity(labelSection.count)
        for i in 0 ..< labelSection.count {
            labels.append(try reader.fixedString(at: labelSection.offset + i * 16, length: 16))
        }

        return GFFDocument(fileType: fileType, version: version, root: try readStruct(0, depth: 0))
    }

    private func readStruct(_ index: Int, depth: Int) throws -> GFFStruct {
        guard depth < Self.maxDepth else { throw AuroraError.invalidFormat("GFF structs nest too deeply") }
        guard index < structs.count else { throw AuroraError.invalidFormat("GFF struct index \(index) out of range") }
        let raw = structs[index]
        var result = GFFStruct(id: raw.id)

        if raw.fieldCount == 1 {
            result.fields = [try readField(Int(raw.data), depth: depth)]
        } else if raw.fieldCount > 1 {
            let count = Int(raw.fieldCount)
            let start = Int(raw.data)
            guard start <= fieldIndices.count, count <= (fieldIndices.count - start) / 4 else {
                throw AuroraError.invalidFormat("GFF field indices out of range")
            }
            result.fields.reserveCapacity(count)
            for i in 0 ..< count {
                let fieldIndex = try reader.uint32(at: fieldIndices.offset + start + i * 4)
                result.fields.append(try readField(Int(fieldIndex), depth: depth))
            }
        }
        return result
    }

    private func dataOffset(_ raw: RawField, _ length: Int) throws -> Int {
        let start = Int(raw.data)
        guard start <= fieldData.count, length <= fieldData.count - start else {
            throw AuroraError.invalidFormat("GFF field data out of range")
        }
        return fieldData.offset + start
    }

    private func readField(_ index: Int, depth: Int) throws -> GFFField {
        guard index < fields.count else { throw AuroraError.invalidFormat("GFF field index \(index) out of range") }
        let raw = fields[index]
        guard Int(raw.label) < labels.count else { throw AuroraError.invalidFormat("GFF label index out of range") }
        guard let type = GFFFieldType(rawValue: raw.type) else {
            throw AuroraError.invalidFormat("unknown GFF field type \(raw.type)")
        }

        let value: GFFValue
        switch type {
        case .byte: value = .byte(UInt8(truncatingIfNeeded: raw.data))
        case .char: value = .char(Int8(truncatingIfNeeded: raw.data))
        case .word: value = .word(UInt16(truncatingIfNeeded: raw.data))
        case .short: value = .short(Int16(truncatingIfNeeded: raw.data))
        case .dword: value = .dword(raw.data)
        case .int: value = .int(Int32(bitPattern: raw.data))
        case .float: value = .float(Float(bitPattern: raw.data))
        case .dword64: value = .dword64(try reader.uint64(at: try dataOffset(raw, 8)))
        case .int64: value = .int64(Int64(bitPattern: try reader.uint64(at: try dataOffset(raw, 8))))
        case .double: value = .double(Double(bitPattern: try reader.uint64(at: try dataOffset(raw, 8))))
        case .exoString, .void:
            let at = try dataOffset(raw, 4)
            let length = Int(try reader.uint32(at: at))
            let bytes = try reader.bytes(at: try dataOffset(raw, 4 + length) + 4, count: length)
            value = type == .void ? .void(bytes) : .exoString(bytes)
        case .resRef:
            let at = try dataOffset(raw, 1)
            let length = Int(try reader.uint8(at: at))
            value = .resRef(try reader.bytes(at: try dataOffset(raw, 1 + length) + 1, count: length))
        case .locString:
            value = .locString(try readLocString(raw))
        case .structure:
            value = .structure(try readStruct(Int(raw.data), depth: depth + 1))
        case .list:
            value = .list(try readList(raw, depth: depth))
        case .orientation:
            let at = try dataOffset(raw, 16)
            value = .orientation(Float(bitPattern: try reader.uint32(at: at)), Float(bitPattern: try reader.uint32(at: at + 4)),
                                 Float(bitPattern: try reader.uint32(at: at + 8)), Float(bitPattern: try reader.uint32(at: at + 12)))
        case .vector:
            let at = try dataOffset(raw, 12)
            value = .vector(Float(bitPattern: try reader.uint32(at: at)), Float(bitPattern: try reader.uint32(at: at + 4)),
                            Float(bitPattern: try reader.uint32(at: at + 8)))
        }
        return GFFField(label: labels[Int(raw.label)], value: value)
    }

    private func readLocString(_ raw: RawField) throws -> GFFLocString {
        let at = try dataOffset(raw, 4)
        let size = Int(try reader.uint32(at: at))
        let start = try dataOffset(raw, 4 + size) + 4
        let end = start + size
        guard size >= 8 else { throw AuroraError.invalidFormat("GFF locstring too small") }
        var cursor = start
        let stringRef = try reader.uint32(at: cursor)
        let count = Int(try reader.uint32(at: cursor + 4))
        cursor += 8
        var result = GFFLocString(stringRef: stringRef)
        for _ in 0 ..< count {
            guard cursor + 8 <= end else { throw AuroraError.invalidFormat("GFF locstring substrings overflow") }
            let languageID = try reader.uint32(at: cursor)
            let length = Int(try reader.uint32(at: cursor + 4))
            cursor += 8
            guard length <= end - cursor else { throw AuroraError.invalidFormat("GFF locstring substring overflow") }
            result.substrings.append(.init(languageID: languageID, bytes: try reader.bytes(at: cursor, count: length)))
            cursor += length
        }
        return result
    }

    private func readList(_ raw: RawField, depth: Int) throws -> [GFFStruct] {
        let start = Int(raw.data)
        guard start <= listIndices.count - 4 else { throw AuroraError.invalidFormat("GFF list offset out of range") }
        let count = Int(try reader.uint32(at: listIndices.offset + start))
        guard count <= (listIndices.count - start - 4) / 4 else { throw AuroraError.invalidFormat("GFF list overflows") }
        var result: [GFFStruct] = []
        result.reserveCapacity(count)
        for i in 0 ..< count {
            let structIndex = try reader.uint32(at: listIndices.offset + start + 4 + i * 4)
            result.append(try readStruct(Int(structIndex), depth: depth + 1))
        }
        return result
    }
}

// MARK: - Writing

/// Lays structs out depth-first in field order, like BioWare's tools and KSE do.
private final class GFFEncoder {
    private var structs = BinaryWriter()
    private var structCount = 0
    private var fields = BinaryWriter()
    private var fieldCount = 0
    private var labels: [String] = []
    private var labelIndex: [String: UInt32] = [:]
    private var fieldData = BinaryWriter()
    private var fieldIndices = BinaryWriter()
    private var listIndices = BinaryWriter()

    func encode(_ document: GFFDocument) -> [UInt8] {
        _ = add(document.root)

        let headerSize = 56
        let structOffset = headerSize
        let fieldOffset = structOffset + structs.count
        let labelOffset = fieldOffset + fields.count
        let fieldDataOffset = labelOffset + labels.count * 16
        let fieldIndicesOffset = fieldDataOffset + fieldData.count
        let listIndicesOffset = fieldIndicesOffset + fieldIndices.count

        var out = BinaryWriter(capacity: listIndicesOffset + listIndices.count)
        out.writeTag(document.fileType)
        out.writeTag(document.version)
        for value in [structOffset, structCount, fieldOffset, fieldCount, labelOffset, labels.count,
                      fieldDataOffset, fieldData.count, fieldIndicesOffset, fieldIndices.count,
                      listIndicesOffset, listIndices.count] {
            out.write(UInt32(value))
        }
        out.write(contentsOf: structs.bytes)
        out.write(contentsOf: fields.bytes)
        for label in labels { out.writeFixed(Array(label.utf8), length: 16) }
        out.write(contentsOf: fieldData.bytes)
        out.write(contentsOf: fieldIndices.bytes)
        out.write(contentsOf: listIndices.bytes)
        return out.bytes
    }

    private func label(_ text: String) -> UInt32 {
        if let index = labelIndex[text] { return index }
        let index = UInt32(labels.count)
        labels.append(text)
        labelIndex[text] = index
        return index
    }

    private func add(_ value: GFFStruct) -> UInt32 {
        let index = structCount
        structCount += 1
        let at = structs.count
        structs.write(value.id)
        structs.write(UInt32(0))
        structs.write(UInt32(value.fields.count))

        switch value.fields.count {
        case 0:
            structs.patch(0xFFFF_FFFF, at: at + 4)
        case 1:
            structs.patch(add(value.fields[0]), at: at + 4)
        default:
            let start = fieldIndices.count
            structs.patch(UInt32(start), at: at + 4)
            fieldIndices.writeZeros(4 * value.fields.count)
            for (i, field) in value.fields.enumerated() {
                fieldIndices.patch(add(field), at: start + 4 * i)
            }
        }
        return UInt32(index)
    }

    private func add(_ field: GFFField) -> UInt32 {
        let index = fieldCount
        fieldCount += 1
        let at = fields.count
        fields.write(field.value.type.rawValue)
        fields.write(label(field.label))
        fields.write(UInt32(0))

        func store(_ data: UInt32) { fields.patch(data, at: at + 8) }
        func storeData(_ body: (inout BinaryWriter) -> Void) {
            store(UInt32(fieldData.count))
            body(&fieldData)
        }

        switch field.value {
        case .byte(let v): store(UInt32(v))
        case .char(let v): store(UInt32(UInt8(bitPattern: v)))
        case .word(let v): store(UInt32(v))
        case .short(let v): store(UInt32(UInt16(bitPattern: v)))
        case .dword(let v): store(v)
        case .int(let v): store(UInt32(bitPattern: v))
        case .float(let v): store(v.bitPattern)
        case .dword64(let v): storeData { $0.write(v) }
        case .int64(let v): storeData { $0.write(UInt64(bitPattern: v)) }
        case .double(let v): storeData { $0.write(v) }
        case .exoString(let raw), .void(let raw):
            storeData {
                $0.write(UInt32(raw.count))
                $0.write(contentsOf: raw)
            }
        case .resRef(let raw):
            storeData {
                let clipped = raw.prefix(255)
                $0.write(UInt8(clipped.count))
                $0.write(contentsOf: clipped)
            }
        case .locString(let loc):
            storeData {
                let payload = loc.substrings.reduce(8) { $0 + 8 + $1.bytes.count }
                $0.write(UInt32(payload))
                $0.write(loc.stringRef)
                $0.write(UInt32(loc.substrings.count))
                for sub in loc.substrings {
                    $0.write(sub.languageID)
                    $0.write(UInt32(sub.bytes.count))
                    $0.write(contentsOf: sub.bytes)
                }
            }
        case .orientation(let a, let b, let c, let d):
            storeData { for f in [a, b, c, d] { $0.write(f) } }
        case .vector(let x, let y, let z):
            storeData { for f in [x, y, z] { $0.write(f) } }
        case .structure(let child):
            store(add(child))
        case .list(let items):
            let start = listIndices.count
            store(UInt32(start))
            listIndices.write(UInt32(items.count))
            listIndices.writeZeros(4 * items.count)
            for (i, item) in items.enumerated() {
                listIndices.patch(add(item), at: start + 4 + 4 * i)
            }
        }
        return UInt32(index)
    }
}
