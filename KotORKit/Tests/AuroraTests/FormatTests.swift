import Aurora
import Foundation
import Testing
import TestFixtures

struct GFFTests {
    static let everyType = gffStruct(0xFFFF_FFFF, [
        "Byte": .byte(250), "Char": .char(-5), "Word": .word(65_000), "Short": .short(-32_000), "DWord": .dword(4_000_000_000),
        "Int": .int(-2_000_000_000), "DWord64": .dword64(18_000_000_000_000_000_000), "Int64": .int64(-9_000_000_000_000_000_000),
        "Float": .float(0.70710677), "TinyFloat": .float(1.0e-9), "NegZero": .float(-0.0), "Double": .double(3.141592653589793),
        "ExoString": .exoString(TextEncoding.windows1252.encode("Élan € 100")), "ResRef": .resRef("p_bastila"),
        "LocString": .locString(GFFLocString(stringRef: 1234, substrings: [.init(languageID: 0, bytes: Array("Hi".utf8)),
                                                                           .init(languageID: 3, bytes: Array("Salut".utf8))])),
        "Void": .void([0, 1, 2, 255]), "Orientation": .orientation(0, 0, 0.38268343, 0.9238795), "Vector": .vector(1.5, -2.25, 1e30),
        "Struct": .structure(gffStruct(42, ["Only": .byte(1)])),
        "EmptyStruct": .structure(GFFStruct(id: 7)),
        "List": .list([gffStruct(1, ["A": .int(1), "B": .list([])]), GFFStruct(id: 2), gffStruct(3, ["C": .exoString([])])]),
        "EmptyList": .list([]),
    ])

    @Test func everyFieldTypeRoundTripsBitExactly() throws {
        let document = GFFDocument(fileType: "UTC ", root: Self.everyType)
        let bytes = document.encoded()
        let decoded = try GFFDocument(bytes: bytes)
        #expect(decoded == document)
        #expect(decoded.fileType == "UTC ")
        #expect(decoded.encoded() == bytes)
        guard case .float(let negativeZero)? = decoded.root["NegZero"] else { Issue.record("missing"); return }
        #expect(negativeZero.bitPattern == (-0.0 as Float).bitPattern)
    }

    @Test func valuesCompareByTheirExactBits() throws {
        // Real TSL area files contain garbage floats such as this signaling NaN.
        let nan = Float(bitPattern: 0xFF80_8EF9)
        let document = GFFDocument(fileType: "GIT ", root: gffStruct(0xFFFF_FFFF, [
            "AreaPoints": .float(nan), "Wide": .double(.nan), "Facing": .orientation(nan, 0, 0, 1), "At": .vector(0, nan, 0),
        ]))
        #expect(document == document)
        #expect(try GFFDocument(bytes: document.encoded()) == document)
        #expect(GFFValue.float(0) != GFFValue.float(-0.0), "a sign change is an edit")
        #expect(GFFValue.float(nan) != GFFValue.float(Float(bitPattern: 0xFF80_8EFA)))
    }

    @Test func structLayoutFollowsTheSpecification() throws {
        let bytes = GFFDocument(fileType: "GFF ", root: Self.everyType).encoded()
        let reader = BinaryReader(bytes)
        let structOffset = Int(try reader.uint32(at: 8))
        let structCount = Int(try reader.uint32(at: 12))
        var sawEmpty = false, sawSingle = false
        for i in 0 ..< structCount {
            let data = try reader.uint32(at: structOffset + i * 12 + 4)
            let count = try reader.uint32(at: structOffset + i * 12 + 8)
            if count == 0 { #expect(data == 0xFFFF_FFFF); sawEmpty = true }
            if try reader.uint32(at: structOffset + i * 12) == 42 { #expect(count == 1); sawSingle = true }
        }
        #expect(sawEmpty && sawSingle)
    }

    @Test func accessorsPreserveFieldTypesAndOrder() {
        var s = gffStruct(0, ["Str": .byte(10), "Name": .exoString([]), "Gold": .dword(5)])
        s.setInteger("Str", 300)
        s.setInteger("Gold", -4)
        s.setInteger("New", 70_000, type: .word)
        #expect(s["Str"] == .byte(255))
        #expect(s["Gold"] == .dword(0))
        #expect(s["New"] == .word(65_535))
        s["Name"] = nil
        #expect(s.fields.map(\.label) == ["Str", "Gold", "New"])
        #expect(s.updateList("Missing") { $0.append(GFFStruct()) } == false)
        #expect(s.updateList("Made", create: true) { $0.append(GFFStruct(id: 9)) })
        #expect(s.list("Made")?.first?.id == 9)
    }

    @Test func locStringTextUsesTheLanguageSubstring() {
        var name = GFFLocString(stringRef: 55, substrings: [.init(languageID: 2, bytes: Array("Carth".utf8))])
        #expect(name.text(encoding: .windows1252, languageID: 2) == "Carth")
        name.setText("Ordo", encoding: .windows1252, languageID: 2)
        #expect(name.stringRef == GFFLocString.noStringRef)
        #expect(name.substrings == [.init(languageID: 2, bytes: Array("Ordo".utf8))])
        var empty = GFFLocString(stringRef: 9)
        empty.setText("Zaalbar", encoding: .windows1252, languageID: 0)
        #expect(empty.substrings.count == 1 && empty.text(encoding: .windows1252) == "Zaalbar")
    }

    @Test func corruptFilesThrowInsteadOfCrashing() {
        let bytes = GFFDocument(fileType: "GFF ", root: Self.everyType).encoded()
        #expect(throws: (any Error).self) { try GFFDocument(bytes: Array(bytes.prefix(40))) }
        #expect(throws: (any Error).self) { try GFFDocument(bytes: Array("GFF V4.0".utf8) + bytes.dropFirst(8)) }
        var generator = SplitMix(seed: 7)
        for _ in 0 ..< 2000 {
            var mutated = bytes
            for _ in 0 ..< 1 + Int(generator.next() % 4) {
                let index = Int(generator.next() % UInt64(mutated.count))
                mutated[index] = UInt8(truncatingIfNeeded: generator.next())
            }
            _ = try? GFFDocument(bytes: mutated)
        }
    }
}

struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

struct ERFTests {
    @Test func archivesRoundTripAndKeepTheirHeader() throws {
        var archive = ERFArchive(fileType: "MOD ", resources: [
            .init(resRef: "AVAILNPC0", type: .utc, resID: 0, data: [1, 2, 3]),
            .init(resRef: "Module", type: .ifo, resID: 7, data: []),
            .init(resRef: "tar_m02ae", type: .sav, resID: 2, data: Array(repeating: 9, count: 1000)),
        ])
        archive.buildYear = 124
        archive.buildDay = 345
        archive.descriptionStrRef = 77
        archive.localizedStrings = [.init(languageID: 0, bytes: Array("Desc".utf8))]
        archive.reserved[3] = 5
        let decoded = try ERFArchive(bytes: archive.encoded())
        #expect(decoded == archive)
        #expect(decoded.index(of: "module", type: .ifo) == 1)
        #expect(decoded.index(of: "module", type: .git) == nil)

        var edited = decoded
        edited.setData([4], for: "availnpc0", type: .utc)
        edited.setData([5], for: "INVENTORY", type: .res)
        #expect(edited.resources[0].resRef == "AVAILNPC0" && edited.resources[0].data == [4])
        #expect(edited.resources.last?.resID == 8)
    }

    @Test func memoryMappedIndexReadsTheSameData() throws {
        let folder = try temporaryDirectory()
        let archive = ERFArchive(fileType: "ERF ", resources: [.init(resRef: "PO_Test", type: .tpc, resID: 0, data: [1, 2, 3, 4])])
        let url = folder.appendingPathComponent("pack.erf")
        try Data(archive.encoded()).write(to: url)
        let index = try ERFIndex(url: url)
        #expect(index.data(for: "po_test", type: .tpc) == [1, 2, 3, 4])
        #expect(index.data(for: "po_test", type: .tga) == nil)
    }

    @Test func rimAndERFIndexesListAndReadTheirResources() throws {
        let folder = try temporaryDirectory()
        let rim = folder.appendingPathComponent("101PER_s.rim")
        try Data(rimFile([("G_W_Unique", .uti, [1, 2, 3]), ("module", .ifo, [4]), ("empty", .uti, [])])).write(to: rim)
        let index = try openArchiveIndex(at: rim)
        #expect(index is RIMIndex)
        #expect(index.entries == [ArchiveEntry(resRef: "g_w_unique", type: .uti), ArchiveEntry(resRef: "module", type: .ifo),
                                  ArchiveEntry(resRef: "empty", type: .uti)])
        #expect(index.data(for: "g_w_UNIQUE", type: .uti) == [1, 2, 3] && index.data(for: "empty", type: .uti) == [])
        #expect(index.data(for: "module", type: .uti) == nil)

        let erf = folder.appendingPathComponent("mod.mod")
        try Data(ERFArchive(fileType: "MOD ", resources: [.init(resRef: "Other", type: .uti, resID: 0, data: [9])]).encoded()).write(to: erf)
        let mod = try openArchiveIndex(at: erf)
        #expect(mod is ERFIndex && mod.entries == [ArchiveEntry(resRef: "other", type: .uti)] && mod.data(for: "other", type: .uti) == [9])

        var broken = rimFile([("a", .uti, [1])])
        broken[12] = 0xFF
        #expect(throws: (any Error).self) { try RIMIndex(data: Data(broken)) }
        #expect(throws: (any Error).self) { try RIMIndex(data: Data(Array("RIM V2.0".utf8) + [UInt8](repeating: 0, count: 12))) }
    }

    @Test func rejectsTablesOutsideTheFile() {
        var bytes = ERFArchive(fileType: "ERF ", resources: [.init(resRef: "a", type: .res, resID: 0, data: [1])]).encoded()
        bytes[16] = 0xFF
        #expect(throws: (any Error).self) { try ERFArchive(bytes: bytes) }
    }
}

struct TableTests {
    @Test func binaryTwoDAReadsSharedCellsAndHexValues() throws {
        let bytes = binary2DA(columns: ["Label", "equipableslots", "name"], rows: [["Rifle", "0x00010", "5"], ["Medpac", "****", "5"], ["", "12", ""]])
        let table = try TwoDA(bytes: bytes)
        #expect(table.columns == ["Label", "equipableslots", "name"])
        #expect(table.rowCount == 3)
        #expect(table.string(0, "label") == "Rifle")
        #expect(table.int(0, "EquipableSlots") == 16)
        #expect(table.string(1, "equipableslots") == nil)
        #expect(table.int(2, "equipableslots") == 12)
        #expect(table.string(2, "label") == nil)
        #expect(table.string(9, "label") == nil)
        #expect(table.string(0, "missing") == nil)
    }

    @Test func binaryTwoDAIgnoresTheStoredDataSize() throws {
        // Modding tools have shipped soundset.2da files that store a data size of 0.
        let table = try TwoDA(bytes: binary2DA(columns: ["label", "resref"], rows: [["None", ""], ["Player_Female_W", "p_playerfw"]],
                                               storedDataSize: 0))
        #expect(table.string(1, "label") == "Player_Female_W" && table.string(1, "resref") == "p_playerfw")
        #expect(table.string(0, "resref") == nil)
    }

    @Test func textTwoDAHandlesDefaultsAndQuotes() throws {
        let text = "2DA V2.0\nDEFAULT: ****\n\n    label   name    icon\n0   FEAT_A  100 \"ip a\"\n1 FEAT_B **** \n"
        let table = try TwoDA(bytes: Array(text.utf8))
        #expect(table.rowCount == 2)
        #expect(table.string(0, "icon") == "ip a")
        #expect(table.string(1, "name") == nil)
        #expect(table.int(0, "name") == 100)
    }

    @Test func talkTablesDecodeTheirCodePage() throws {
        let tlk = try TalkTable(data: Data(talkTable(["Hello", "", "Café €5"], language: 2)))
        #expect(tlk.languageID == 2)
        #expect(tlk.string(0) == "Hello")
        #expect(tlk.string(1) == nil)
        #expect(tlk.string(2) == "Café €5")
        #expect(tlk.string(3) == nil)
        #expect(tlk.string(GFFLocString.noStringRef) == nil)
        let polish = try TalkTable(data: Data(talkTable(["Zażółć"], language: 5, encoding: .windows1250)))
        #expect(polish.string(0) == "Zażółć")
    }

    @Test func talkTableEntriesNameTheirSounds() throws {
        var bytes = talkTable(["Yeah?", "No sound", "Flag cleared"], sounds: [0: "p_Atton_Slct1", 2: "p_atton_slct2"])
        bytes[20 + 2 * 40] &= ~2
        let tlk = try TalkTable(data: Data(bytes))
        #expect(tlk.soundResRef(0) == "p_Atton_Slct1")
        #expect(tlk.soundResRef(1) == nil && tlk.soundResRef(2) == nil)
        #expect(tlk.soundResRef(3) == nil && tlk.soundResRef(GFFLocString.noStringRef) == nil)
    }

    @Test func keyAndBIFResolveCaseInsensitively() throws {
        let root = try temporaryDirectory()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Data"), withIntermediateDirectories: true)
        try Data(keyFile(bifs: ["data\\two.bif"], entries: [KeyEntry("Feat", .twoDA, bif: 0, index: 1), KeyEntry("feat", .uti, bif: 0, index: 0)]))
            .write(to: root.appendingPathComponent("CHITIN.KEY"))
        try Data(bifFile([(.uti, [9, 9]), (.twoDA, [1, 2, 3])])).write(to: root.appendingPathComponent("Data/TWO.BIF"))
        let archive = try KeyArchive(root: root)
        #expect(try archive.resource("FEAT", .twoDA) == [1, 2, 3])
        #expect(try archive.resource("feat", .uti) == [9, 9])
        #expect(try archive.resource("spells", .twoDA) == nil)
        #expect(archive.entries(of: .uti).map(\.resRef) == ["feat"])
    }
}

struct SoundTests {
    @Test func soundSetsListTalkTableReferences() throws {
        let set = try SoundSetFile(bytes: soundSetFile([122_703, GFFLocString.noStringRef, 7]))
        #expect(set.strRefs == [122_703, GFFLocString.noStringRef, 7])
        #expect(throws: (any Error).self) { try SoundSetFile(bytes: Array("SSF V1.0".utf8) + [12, 0, 0, 0]) }
        #expect(throws: (any Error).self) { try SoundSetFile(bytes: Array("SSF V1.1".utf8) + [200, 0, 0, 0]) }
        #expect(throws: (any Error).self) { try SoundSetFile(bytes: Array("SSF V1.1".utf8)) }
    }

    @Test func soundContainersAreUnwrapped() throws {
        let wave = waveFile([0, 100, -100, 32767])
        let plain = try #require(GameSound.playable(wave))
        #expect(plain.bytes == wave && plain.format == .wave)

        let stream = try #require(GameSound.playable(streamSoundFile([0, 100, -100, 32767])))
        #expect(stream.bytes == wave && stream.format == .wave)

        let mp3: [UInt8] = [0xFF, 0xFB, 0x38, 0xC4, 1, 2, 3]
        let voice = try #require(GameSound.playable(voiceOverFile(mp3)))
        #expect(voice.bytes == mp3 && voice.format == .mp3)
        #expect(GameSound.playable(mp3)?.format == .mp3)
        #expect(GameSound.playable(Array("ID3".utf8) + mp3)?.format == .mp3)

        #expect(GameSound.playable(Array("RIFF\0\0\0\0WAVE".utf8)) == nil)
        #expect(GameSound.playable([1, 2, 3, 4]) == nil)
    }
}

struct ImageTests {
    @Test func uncompressedTPCIsFlippedToTopDown() throws {
        let red: [UInt8] = [255, 0, 0, 255], green: [UInt8] = [0, 255, 0, 128]
        let image = try TPCDecoder.decode(tpcRGBA(width: 2, height: 2, rowsTopDown: [red + red, green + green]))
        #expect(image.width == 2 && image.height == 2)
        #expect(Array(image.pixels.prefix(4)) == red)
        #expect(Array(image.pixels.suffix(4)) == green)
    }

    @Test func dxt1AndDXT5BlocksDecode() throws {
        func header(_ dataSize: Int, encoding: UInt8, width: Int = 4, height: Int = 4) -> [UInt8] {
            var w = BinaryWriter()
            w.write(UInt32(dataSize)); w.write(Float(0)); w.write(UInt16(width)); w.write(UInt16(height))
            w.write(encoding); w.write(UInt8(1)); w.writeZeros(114)
            return w.bytes
        }
        // DXT1: color0 pure red (0xF800) > color1 pure blue (0x001F); stored row 0 uses index 1, the rest index 0.
        let dxt1 = header(8, encoding: 2) + [0x00, 0xF8, 0x1F, 0x00, 0b0101_0101, 0, 0, 0]
        let image = try TPCDecoder.decode(dxt1)
        #expect(Array(image.pixels.prefix(4)) == [255, 0, 0, 255])
        #expect(Array(image.pixels.suffix(4)) == [0, 0, 255, 255])

        // DXT5 with alpha0 = 255, alpha1 = 0; texel 0 uses alpha index 1 (transparent).
        let dxt5 = header(16, encoding: 4) + [255, 0, 0b0000_0001, 0, 0, 0, 0, 0] + [0xFF, 0xFF, 0xFF, 0xFF, 0, 0, 0, 0]
        let alpha = try TPCDecoder.decode(dxt5)
        #expect(alpha.pixels[(3 * 4) * 4 + 3] == 0)
        #expect(alpha.pixels[3] == 255)
        #expect(Array(alpha.pixels.prefix(3)) == [255, 255, 255])
    }

    @Test func tgaHandlesOriginAndRunLengthEncoding() throws {
        var bottomUp = [UInt8](repeating: 0, count: 18)
        bottomUp[2] = 2; bottomUp[12] = 1; bottomUp[14] = 2; bottomUp[16] = 24
        bottomUp += [1, 2, 3, 4, 5, 6]
        let image = try TGADecoder.decode(bottomUp)
        #expect(Array(image.pixels.prefix(4)) == [6, 5, 4, 255])
        #expect(Array(image.pixels.suffix(4)) == [3, 2, 1, 255])

        var rle = [UInt8](repeating: 0, count: 18)
        rle[2] = 10; rle[12] = 3; rle[14] = 1; rle[16] = 32; rle[17] = 0x28
        rle += [0x81, 10, 20, 30, 40, 0x00, 1, 2, 3, 4]
        let decoded = try TGADecoder.decode(rle)
        #expect(decoded.pixels == [30, 20, 10, 40, 30, 20, 10, 40, 3, 2, 1, 4])

        var gray = [UInt8](repeating: 0, count: 18)
        gray[2] = 3; gray[12] = 1; gray[14] = 1; gray[16] = 8; gray[17] = 0x20
        #expect(try TGADecoder.decode(gray + [77]).pixels == [77, 77, 77, 255])
    }
}

struct EncodingTests {
    @Test func windowsCodePagesRoundTrip() {
        let text = "Élan – “quoted” €"
        let bytes = TextEncoding.windows1252.encode(text)
        #expect(bytes.count == text.count)
        #expect(TextEncoding.windows1252.decode(bytes) == text)
        #expect(TextEncoding.windows1252.decode([0x41, 0x81, 0x42]).count == 3)
        #expect(TextEncoding.windows1252.decode([0x48, 0x69, 0, 0]) == "Hi")
        #expect(TextEncoding.forLanguage(131) == .windows932)
        #expect(TextEncoding.windows932.decode(TextEncoding.windows932.encode("ジェダイ")) == "ジェダイ")
        #expect(!TextEncoding.windows1252.canEncode("ジェダイ"))
    }
}
