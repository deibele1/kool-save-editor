// KSEMac — a KotOR savegame editor for macOS.
// Game-specific constants from KotOR Savegame Editor (KSE) by tk102, Fair Strides and
// the KSE team (https://gitlab.com/kotorsge-team/kse). GNU GPL v3 or later.

import Aurora
import Foundation

public enum Game: String, Codable, CaseIterable, Sendable, Identifiable {
    case kotor1
    case kotor2

    public var id: String { rawValue }

    /// The game a running application is, by bundle identifier; nil for other applications.
    /// TSL is the “com.aspyr.kotor2” family (Steam com.aspyr.kotor2.steam, Mac App Store
    /// com.aspyr.kotor2.appstore and com.aspyr.kotor2), KotOR the “com.aspyr.kotor” family
    /// (Mac App Store com.aspyr.kotor and com.aspyr.kotor.appstore, other com.aspyr.kotor.*
    /// releases); the App Store identifiers are also the container names in `SaveDiscovery`.
    /// Each game's launcher runs the engine as a second executable in the same bundle, which
    /// reports the same identifier.
    public init?(bundleIdentifier: String) {
        let id = bundleIdentifier.lowercased()
        // TSL first: its identifiers also start with "com.aspyr.kotor".
        if id.hasPrefix("com.aspyr.kotor2") {
            self = .kotor2
        } else if id == "com.aspyr.kotor" || id.hasPrefix("com.aspyr.kotor.") {
            self = .kotor1
        } else {
            return nil
        }
    }

    public var title: String {
        switch self {
        case .kotor1: "Knights of the Old Republic"
        case .kotor2: "The Sith Lords"
        }
    }

    public var shortTitle: String {
        switch self {
        case .kotor1: "KotOR"
        case .kotor2: "KotOR II"
        }
    }

    /// Party NPC names by `PT_MEMBER_ID`, used when a companion's sheet is unavailable.
    public var standardNPCNames: [Int: String] {
        switch self {
        case .kotor1:
            [0: "Bastila", 1: "Canderous", 2: "Carth", 3: "HK-47", 4: "Jolee", 5: "Juhani", 6: "Mission",
             7: "T3-M4", 8: "Zaalbar"]
        case .kotor2:
            [0: "Atton", 1: "Bao-Dur", 2: "Mandalore", 3: "G0-T0", 4: "Handmaiden", 5: "HK-47", 6: "Kreia",
             7: "Mira", 8: "T3-M4", 9: "Visas Marr", 10: "Hanharr", 11: "Disciple"]
        }
    }

    public var hasInfluence: Bool { self == .kotor2 }
    public var hasCraftingResources: Bool { self == .kotor2 }
    public var hasSecondWeaponSet: Bool { self == .kotor2 }
    public var hasItemUpgradeSlots: Bool { self == .kotor2 }

    /// The level cap of the unmodified game, for when its exptable.2da can't be read
    /// (`GameData.maximumLevel`).
    public var maximumLevel: Int { self == .kotor1 ? 20 : 50 }

    /// HMAC-SHA1 keys the Xbox releases use to sign save files.
    public var signatureKey: [UInt8] {
        switch self {
        case .kotor1: [0x07, 0xDF, 0x71, 0xE6, 0xB1, 0xFB, 0x1C, 0x82, 0x78, 0x26, 0x68, 0x3C, 0x2A, 0x48, 0x42, 0xD3]
        case .kotor2: [0x67, 0x77, 0x01, 0x4B, 0xB4, 0xAD, 0xE4, 0x21, 0x8B, 0x3D, 0x98, 0x67, 0xA8, 0xBA, 0x76, 0x3C]
        }
    }
}
