// KSEMac — a KotOR savegame editor for macOS.
// KotOR sound sets (SSF V1.1) and the containers the games store their sounds in.
// The SSF reader is a Swift port of the KotOR part of xoreos-tools' Aurora::SSFFile
// (https://github.com/xoreos/xoreos-tools); the containers are unwrapped as xoreos'
// sound manager does (https://github.com/xoreos/xoreos). GNU GPL v3 or later.
//
// Differences from the C++ originals: SSF files are only read, and only in KotOR's variant
// (NWN's V1.0 and NWN2's V1.1, whose entries carry sound file names, are not supported).
// Sounds are not decoded: the WAV or MP3 inside is returned for the system to play.

/// A creature's sound set: one talk table reference per situation (battle cry, pain grunt…);
/// the talk table entry names the sound file.
public struct SoundSetFile: Sendable, Equatable {
    /// One reference per slot; `GFFLocString.noStringRef` marks an empty slot.
    public var strRefs: [UInt32]

    public init(strRefs: [UInt32]) {
        self.strRefs = strRefs
    }

    public init(bytes: [UInt8]) throws {
        let reader = BinaryReader(bytes)
        guard try reader.fixedString(at: 0, length: 4) == "SSF " else { throw AuroraError.invalidFormat("not an SSF file") }
        let version = try reader.fixedString(at: 4, length: 4)
        guard version == "V1.1" else { throw AuroraError.unsupportedVersion("SSF \(version)") }
        let offset = Int(try reader.uint32(at: 8))
        guard offset >= 12, offset <= bytes.count else { throw AuroraError.invalidFormat("SSF entry table lies outside the file") }
        strRefs = try stride(from: offset, through: bytes.count - 4, by: 4).map { try reader.uint32(at: $0) }
    }
}

public enum GameSound {
    public enum Format: Sendable {
        case wave
        case mp3
    }

    /// The playable audio in a KotOR sound file. Besides plain WAV and MP3 files the games use
    /// two disguises: stream sounds put a fake MP3 frame (470 bytes) before a real WAV, and voice
    /// over and music are MP3 streams after a WAV header whose data chunk is empty.
    public static func playable(_ bytes: [UInt8]) -> (bytes: [UInt8], format: Format)? {
        var bytes = bytes
        if bytes.starts(with: [0xFF, 0xF3, 0x60, 0xC4]) {
            guard let riff = firstRange(of: riffTag, in: bytes.prefix(4096)) else { return (bytes, .mp3) }
            bytes.removeFirst(riff)
        }
        if bytes.starts(with: riffTag) {
            guard bytes.count >= 12, Array(bytes[8 ..< 12]) == Array("WAVE".utf8) else { return nil }
            var position = 12
            while position <= bytes.count - 8 {
                let size = Int(UInt32(bytes[position + 4]) | UInt32(bytes[position + 5]) << 8
                    | UInt32(bytes[position + 6]) << 16 | UInt32(bytes[position + 7]) << 24)
                if Array(bytes[position ..< position + 4]) == Array("data".utf8) {
                    let start = position + 8
                    return size == 0 && start < bytes.count ? (Array(bytes[start...]), .mp3) : (bytes, .wave)
                }
                position += 8 + size + size % 2
            }
            return nil
        }
        let isMP3 = bytes.starts(with: Array("ID3".utf8)) || (bytes.count > 1 && bytes[0] == 0xFF && bytes[1] & 0xE0 == 0xE0)
        return isMP3 ? (bytes, .mp3) : nil
    }

    private static let riffTag = Array("RIFF".utf8)

    private static func firstRange(of tag: [UInt8], in bytes: ArraySlice<UInt8>) -> Int? {
        guard bytes.count >= tag.count else { return nil }
        return (bytes.startIndex ... bytes.endIndex - tag.count).first { bytes[$0 ..< $0 + tag.count].elementsEqual(tag) }
    }
}
