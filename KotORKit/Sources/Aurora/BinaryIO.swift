// KSEMac — a KotOR savegame editor for macOS.
// Little-endian stream helpers, after xoreos-tools' Common::ReadStream/WriteStream
// (https://github.com/xoreos/xoreos-tools). GNU GPL v3 or later.

import Foundation

public enum AuroraError: Error, LocalizedError, Equatable, Sendable {
    case truncated(String)
    case invalidFormat(String)
    case unsupportedVersion(String)
    case notFound(String)

    public var errorDescription: String? {
        switch self {
        case .truncated(let what): "The file ends unexpectedly (\(what))."
        case .invalidFormat(let what): "The file is not valid: \(what)."
        case .unsupportedVersion(let what): "Unsupported file version: \(what)."
        case .notFound(let what): "Not found: \(what)."
        }
    }
}

/// Bounds-checked little-endian reader over an in-memory byte buffer.
public struct BinaryReader: Sendable {
    public let bytes: [UInt8]
    public private(set) var offset: Int

    public init(_ bytes: [UInt8], offset: Int = 0) {
        self.bytes = bytes
        self.offset = offset
    }

    public init(_ data: Data) {
        self.init([UInt8](data))
    }

    public var count: Int { bytes.count }

    public mutating func seek(to position: Int) throws {
        guard position >= 0, position <= bytes.count else {
            throw AuroraError.truncated("seek to \(position) of \(bytes.count)")
        }
        offset = position
    }

    public mutating func skip(_ count: Int) throws {
        try seek(to: offset + count)
    }

    @inline(__always)
    private func require(_ length: Int, at position: Int) throws {
        guard length >= 0, position >= 0, position <= bytes.count - length else {
            throw AuroraError.truncated("\(length) bytes at \(position) of \(bytes.count)")
        }
    }

    public func uint8(at position: Int) throws -> UInt8 {
        try require(1, at: position)
        return bytes[position]
    }

    public func uint16(at position: Int) throws -> UInt16 {
        try require(2, at: position)
        return UInt16(bytes[position]) | UInt16(bytes[position + 1]) << 8
    }

    public func uint32(at position: Int) throws -> UInt32 {
        try require(4, at: position)
        return UInt32(bytes[position]) | UInt32(bytes[position + 1]) << 8
            | UInt32(bytes[position + 2]) << 16 | UInt32(bytes[position + 3]) << 24
    }

    public func uint64(at position: Int) throws -> UInt64 {
        UInt64(try uint32(at: position)) | UInt64(try uint32(at: position + 4)) << 32
    }

    public func bytes(at position: Int, count: Int) throws -> [UInt8] {
        try require(count, at: position)
        return Array(bytes[position ..< position + count])
    }

    /// Reads a fixed-size, NUL-padded ASCII field.
    public func fixedString(at position: Int, length: Int) throws -> String {
        try require(length, at: position)
        var end = position
        while end < position + length, bytes[end] != 0 { end += 1 }
        return String(decoding: bytes[position ..< end], as: UTF8.self)
    }

    public mutating func readUInt8() throws -> UInt8 {
        defer { offset += 1 }
        return try uint8(at: offset)
    }

    public mutating func readUInt16() throws -> UInt16 {
        defer { offset += 2 }
        return try uint16(at: offset)
    }

    public mutating func readUInt32() throws -> UInt32 {
        defer { offset += 4 }
        return try uint32(at: offset)
    }

    public mutating func readUInt64() throws -> UInt64 {
        defer { offset += 8 }
        return try uint64(at: offset)
    }

    public mutating func readInt32() throws -> Int32 {
        Int32(bitPattern: try readUInt32())
    }

    public mutating func readFloat() throws -> Float {
        Float(bitPattern: try readUInt32())
    }

    public mutating func readBytes(_ count: Int) throws -> [UInt8] {
        defer { offset += count }
        return try bytes(at: offset, count: count)
    }

    public mutating func readFixedString(_ length: Int) throws -> String {
        defer { offset += length }
        return try fixedString(at: offset, length: length)
    }

    /// Reads a four character file type or version tag such as `GFF ` or `V3.2`.
    public mutating func readTag() throws -> String {
        let raw = try readBytes(4)
        return String(decoding: raw, as: UTF8.self)
    }
}

/// Little-endian writer that appends to a growing byte buffer.
public struct BinaryWriter: Sendable {
    public private(set) var bytes: [UInt8] = []

    public init(capacity: Int = 0) {
        bytes.reserveCapacity(capacity)
    }

    public var count: Int { bytes.count }

    public mutating func write(_ value: UInt8) {
        bytes.append(value)
    }

    public mutating func write(_ value: UInt16) {
        bytes.append(UInt8(truncatingIfNeeded: value))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
    }

    public mutating func write(_ value: UInt32) {
        bytes.append(UInt8(truncatingIfNeeded: value))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
        bytes.append(UInt8(truncatingIfNeeded: value >> 16))
        bytes.append(UInt8(truncatingIfNeeded: value >> 24))
    }

    public mutating func write(_ value: UInt64) {
        write(UInt32(truncatingIfNeeded: value))
        write(UInt32(truncatingIfNeeded: value >> 32))
    }

    public mutating func write(_ value: Float) {
        write(value.bitPattern)
    }

    public mutating func write(_ value: Double) {
        write(value.bitPattern)
    }

    public mutating func write<C: Collection>(contentsOf data: C) where C.Element == UInt8 {
        bytes.append(contentsOf: data)
    }

    public mutating func writeZeros(_ count: Int) {
        bytes.append(contentsOf: repeatElement(0, count: count))
    }

    /// Writes a four character tag, padding with spaces or truncating as needed.
    public mutating func writeTag(_ tag: String) {
        var raw = Array(tag.utf8.prefix(4))
        while raw.count < 4 { raw.append(0x20) }
        bytes.append(contentsOf: raw)
    }

    /// Writes `data` into a fixed-size field, truncating or NUL padding it.
    public mutating func writeFixed<C: Collection>(_ data: C, length: Int) where C.Element == UInt8 {
        let prefix = data.prefix(length)
        bytes.append(contentsOf: prefix)
        writeZeros(length - prefix.count)
    }

    public mutating func patch(_ value: UInt32, at position: Int) {
        bytes[position] = UInt8(truncatingIfNeeded: value)
        bytes[position + 1] = UInt8(truncatingIfNeeded: value >> 8)
        bytes[position + 2] = UInt8(truncatingIfNeeded: value >> 16)
        bytes[position + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }
}
