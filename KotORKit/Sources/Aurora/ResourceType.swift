// KSEMac — a KotOR savegame editor for macOS.
// Resource type IDs as used by KotOR archives (after xoreos-tools' Aurora::FileType
// and KSE's Bioware::ERF tables). GNU GPL v3 or later.

/// The numeric resource type stored in ERF, RIM and KEY tables.
public struct ResourceType: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    public init?(extension ext: String) {
        guard let raw = Self.byExtension[ext.lowercased()] else { return nil }
        self.init(rawValue: raw)
    }

    public var fileExtension: String {
        Self.extensions[rawValue] ?? String(format: "%04x", rawValue)
    }

    public var description: String { fileExtension }

    public static let res = ResourceType(rawValue: 0x0000)
    public static let bmp = ResourceType(rawValue: 0x0001)
    public static let tga = ResourceType(rawValue: 0x0003)
    public static let wav = ResourceType(rawValue: 0x0004)
    public static let txt = ResourceType(rawValue: 0x000A)
    public static let mdl = ResourceType(rawValue: 0x07D2)
    public static let ncs = ResourceType(rawValue: 0x07DA)
    public static let are = ResourceType(rawValue: 0x07DC)
    public static let ifo = ResourceType(rawValue: 0x07DE)
    public static let twoDA = ResourceType(rawValue: 0x07E1)
    public static let tlk = ResourceType(rawValue: 0x07E2)
    public static let txi = ResourceType(rawValue: 0x07E6)
    public static let git = ResourceType(rawValue: 0x07E7)
    public static let uti = ResourceType(rawValue: 0x07E9)
    public static let utc = ResourceType(rawValue: 0x07EB)
    public static let dlg = ResourceType(rawValue: 0x07ED)
    public static let gff = ResourceType(rawValue: 0x07F5)
    public static let fac = ResourceType(rawValue: 0x07F6)
    public static let jrl = ResourceType(rawValue: 0x0808)
    public static let sav = ResourceType(rawValue: 0x0809)
    public static let ssf = ResourceType(rawValue: 0x080C)
    public static let tpc = ResourceType(rawValue: 0x0BBF)
    public static let erf = ResourceType(rawValue: 0x270D)
    public static let bif = ResourceType(rawValue: 0x270E)
    public static let key = ResourceType(rawValue: 0x270F)

    static let extensions: [UInt16: String] = [
        0x0000: "res", 0x0001: "bmp", 0x0002: "mve", 0x0003: "tga", 0x0004: "wav", 0x0006: "plt",
        0x0007: "ini", 0x0008: "mp3", 0x0009: "mpg", 0x000A: "txt", 0x000B: "wma", 0x000C: "wmv",
        0x000D: "xmv", 0x07D0: "plh", 0x07D1: "tex", 0x07D2: "mdl", 0x07D3: "thg", 0x07D5: "fnt",
        0x07D7: "lua", 0x07D8: "slt", 0x07D9: "nss", 0x07DA: "ncs", 0x07DB: "mod", 0x07DC: "are",
        0x07DD: "set", 0x07DE: "ifo", 0x07DF: "bic", 0x07E0: "wok", 0x07E1: "2da", 0x07E2: "tlk",
        0x07E6: "txi", 0x07E7: "git", 0x07E8: "bti", 0x07E9: "uti", 0x07EA: "btc", 0x07EB: "utc",
        0x07ED: "dlg", 0x07EE: "itp", 0x07EF: "btt", 0x07F0: "utt", 0x07F1: "dds", 0x07F2: "bts",
        0x07F3: "uts", 0x07F4: "ltr", 0x07F5: "gff", 0x07F6: "fac", 0x07F7: "bte", 0x07F8: "ute",
        0x07F9: "btd", 0x07FA: "utd", 0x07FB: "btp", 0x07FC: "utp", 0x07FD: "dft", 0x07FE: "gic",
        0x07FF: "gui", 0x0800: "css", 0x0801: "ccs", 0x0802: "btm", 0x0803: "utm", 0x0804: "dwk",
        0x0805: "pwk", 0x0806: "btg", 0x0807: "utg", 0x0808: "jrl", 0x0809: "sav", 0x080A: "utw",
        0x080B: "4pc", 0x080C: "ssf", 0x080D: "hak", 0x080E: "nwm", 0x080F: "bik", 0x0810: "ndb",
        0x0811: "ptm", 0x0812: "ptt", 0x0BB8: "lyt", 0x0BB9: "vis", 0x0BBA: "rim", 0x0BBB: "pth",
        0x0BBC: "lip", 0x0BBD: "bwm", 0x0BBE: "txb", 0x0BBF: "tpc", 0x0BC0: "mdx", 0x0BC1: "rsv",
        0x0BC2: "sig", 0x0BC3: "xbx", 0x270D: "erf", 0x270E: "bif", 0x270F: "key",
    ]

    static let byExtension: [String: UInt16] = Dictionary(
        extensions.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
}
