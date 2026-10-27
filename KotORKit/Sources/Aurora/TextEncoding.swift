// KSEMac — a KotOR savegame editor for macOS.
// Language and code page tables from xoreos-tools' Aurora::LanguageManager
// (https://github.com/xoreos/xoreos-tools). GNU GPL v3 or later.

import CoreFoundation
import Foundation

/// A legacy code page used by the Odyssey engine for strings in GFF and TLK files.
public struct TextEncoding: Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let encoding: String.Encoding

    public static let windows1252 = TextEncoding(id: "cp1252", name: "Western (Windows-1252)", encoding: .windowsCP1252)
    public static let windows1250 = TextEncoding(id: "cp1250", name: "Central European (Windows-1250)", encoding: .windowsCP1250)
    public static let windows1251 = TextEncoding(id: "cp1251", name: "Cyrillic (Windows-1251)", encoding: .windowsCP1251)
    public static let windows932 = TextEncoding(id: "cp932", name: "Japanese (Windows-932)", cf: .dosJapanese)
    public static let windows936 = TextEncoding(id: "cp936", name: "Simplified Chinese (Windows-936)", cf: .dosChineseSimplif)
    public static let windows949 = TextEncoding(id: "cp949", name: "Korean (Windows-949)", cf: .dosKorean)
    public static let windows950 = TextEncoding(id: "cp950", name: "Traditional Chinese (Windows-950)", cf: .dosChineseTrad)

    public static let all: [TextEncoding] = [
        .windows1252, .windows1250, .windows1251, .windows932, .windows936, .windows949, .windows950,
    ]

    private init(id: String, name: String, encoding: String.Encoding) {
        self.id = id
        self.name = name
        self.encoding = encoding
    }

    private init(id: String, name: String, cf: CFStringEncodings) {
        let raw = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(cf.rawValue))
        self.init(id: id, name: name, encoding: String.Encoding(rawValue: raw))
    }

    public static func named(_ id: String) -> TextEncoding? {
        all.first { $0.id == id }
    }

    /// The code page the games use for a talk table / locstring language ID
    /// (KotOR and TSL share the Neverwinter Nights table).
    public static func forLanguage(_ language: UInt32) -> TextEncoding {
        switch language {
        case 5: .windows1250
        case 128: .windows949
        case 129: .windows950
        case 130: .windows936
        case 131: .windows932
        default: .windows1252
        }
    }

    public func decode<C: Collection>(_ bytes: C) -> String where C.Element == UInt8 {
        var raw = Array(bytes)
        while raw.last == 0 { raw.removeLast() }
        if raw.isEmpty { return "" }
        if raw.allSatisfy({ $0 < 0x80 }) { return String(decoding: raw, as: UTF8.self) }
        if let text = String(bytes: raw, encoding: encoding) { return text }
        // Windows-1252 leaves five bytes undefined; Latin-1 decodes every byte.
        return String(bytes: raw, encoding: .isoLatin1) ?? String(decoding: raw, as: UTF8.self)
    }

    public func encode(_ string: String) -> [UInt8] {
        if let data = string.data(using: encoding, allowLossyConversion: true) { return [UInt8](data) }
        return [UInt8](string.data(using: .ascii, allowLossyConversion: true) ?? Data())
    }

    public func canEncode(_ string: String) -> Bool {
        string.data(using: encoding, allowLossyConversion: false) != nil
    }
}
