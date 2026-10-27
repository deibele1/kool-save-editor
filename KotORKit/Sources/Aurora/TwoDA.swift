// KSEMac — a KotOR savegame editor for macOS.
// BioWare 2DA tables, binary V2.b and text V2.0.
// Swift port of xoreos-tools' Aurora::TwoDAFile (https://github.com/xoreos/xoreos-tools).
// GNU GPL v3 or later.
//
// Differences from the C++ original: rows are addressed by position, as the game does
// (KSE keyed rows by their label text); cell offsets are bounds-checked; columns are
// looked up case-insensitively; GDA (Dragon Age) and CSV output are not supported.

import Foundation

public struct TwoDA: Sendable {
    public let columns: [String]
    public let rowLabels: [String]
    private let cells: [String]
    private let columnLookup: [String: Int]

    public var rowCount: Int { rowLabels.count }

    public init(columns: [String], rows: [[String]]) {
        self.columns = columns
        rowLabels = rows.indices.map(String.init)
        cells = rows.flatMap { row in (0 ..< columns.count).map { $0 < row.count ? Self.normalize(row[$0]) : "" } }
        columnLookup = Self.lookupTable(columns)
    }

    public init(bytes: [UInt8]) throws {
        var reader = BinaryReader(bytes)
        guard try reader.readTag() == "2DA " else { throw AuroraError.invalidFormat("not a 2DA file") }
        let version = try reader.readTag()
        switch version {
        case "V2.b": (columns, rowLabels, cells) = try Self.readBinary(bytes)
        case "V2.0": (columns, rowLabels, cells) = try Self.readText(bytes)
        default: throw AuroraError.unsupportedVersion("2DA \(version)")
        }
        columnLookup = Self.lookupTable(columns)
    }

    private static func lookupTable(_ columns: [String]) -> [String: Int] {
        Dictionary(columns.enumerated().map { ($1.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
    }

    private static func normalize(_ cell: String) -> String {
        cell == "****" ? "" : cell
    }

    public func columnIndex(_ name: String) -> Int? {
        columnLookup[name.lowercased()]
    }

    /// The cell text, or nil when the row/column is missing or the cell is empty (`****`).
    public func string(_ row: Int, _ column: String) -> String? {
        guard row >= 0, row < rowCount, let col = columnIndex(column) else { return nil }
        let value = cells[row * columns.count + col]
        return value.isEmpty ? nil : value
    }

    /// Integer cells, including the hexadecimal `0x…` values used by baseitems.2da.
    public func int(_ row: Int, _ column: String) -> Int? {
        guard let text = string(row, column)?.trimmingCharacters(in: .whitespaces) else { return nil }
        if text.lowercased().hasPrefix("0x") { return Int(text.dropFirst(2), radix: 16) }
        return Int(text)
    }

    // MARK: Binary V2.b

    private static func readBinary(_ bytes: [UInt8]) throws -> ([String], [String], [String]) {
        var position = 8
        // The rest of the first line is padding.
        while position < bytes.count, bytes[position] != 0x0A { position += 1 }
        position += 1

        var columns: [String] = []
        var token: [UInt8] = []
        while true {
            guard position < bytes.count else { throw AuroraError.truncated("2DA column headers") }
            let byte = bytes[position]
            position += 1
            if byte == 0x09 || byte == 0 {
                if !token.isEmpty { columns.append(String(decoding: token, as: UTF8.self)) }
                token.removeAll()
                if byte == 0 { break }
            } else {
                token.append(byte)
            }
        }

        let reader = BinaryReader(bytes)
        let rowCount = Int(try reader.uint32(at: position))
        position += 4

        var labels: [String] = []
        labels.reserveCapacity(rowCount)
        for _ in 0 ..< rowCount {
            var label: [UInt8] = []
            while true {
                guard position < bytes.count else { throw AuroraError.truncated("2DA row labels") }
                let byte = bytes[position]
                position += 1
                if byte == 0x09 || byte == 0 { break }
                label.append(byte)
            }
            labels.append(String(decoding: label, as: UTF8.self))
        }

        let cellCount = rowCount * columns.count
        guard cellCount <= (bytes.count - position) / 2 else { throw AuroraError.truncated("2DA cell offsets") }
        var offsets: [Int] = []
        offsets.reserveCapacity(cellCount)
        for i in 0 ..< cellCount { offsets.append(Int(try reader.uint16(at: position + i * 2))) }
        position += cellCount * 2
        let dataSize = Int(try reader.uint16(at: position))
        let dataStart = position + 2
        let dataEnd = min(bytes.count, dataStart + dataSize)

        var cache: [Int: String] = [:]
        let cells = try offsets.map { offset -> String in
            if let cached = cache[offset] { return cached }
            let start = dataStart + offset
            guard start <= dataEnd else { throw AuroraError.invalidFormat("2DA cell offset out of range") }
            var end = start
            while end < dataEnd, bytes[end] != 0 { end += 1 }
            let text = normalize(String(decoding: bytes[start ..< end], as: UTF8.self))
            cache[offset] = text
            return text
        }
        return (columns, labels, cells)
    }

    // MARK: Text V2.0

    private static func tokenize(_ line: Substring) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        var hasToken = false
        for character in line {
            if character == "\"" {
                inQuotes.toggle()
                hasToken = true
            } else if !inQuotes, character == " " || character == "\t" {
                if hasToken { tokens.append(current) }
                current = ""
                hasToken = false
            } else {
                current.append(character)
                hasToken = true
            }
        }
        if hasToken { tokens.append(current) }
        return tokens
    }

    private static func readText(_ bytes: [UInt8]) throws -> ([String], [String], [String]) {
        let text = String(decoding: bytes, as: UTF8.self)
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" })
            .dropFirst()
            .map { $0 }
        if let first = lines.first, first.trimmingCharacters(in: .whitespaces).uppercased().hasPrefix("DEFAULT:") {
            lines.removeFirst()
        }
        guard let headerIndex = lines.firstIndex(where: { !tokenize($0).isEmpty }) else {
            throw AuroraError.invalidFormat("2DA has no column headers")
        }
        let columns = tokenize(lines[headerIndex])
        var labels: [String] = []
        var cells: [String] = []
        for line in lines[(headerIndex + 1)...] {
            let tokens = tokenize(line)
            guard let label = tokens.first else { continue }
            labels.append(label)
            for i in 0 ..< columns.count {
                cells.append(i + 1 < tokens.count ? normalize(tokens[i + 1]) : "")
            }
        }
        return (columns, labels, cells)
    }
}
