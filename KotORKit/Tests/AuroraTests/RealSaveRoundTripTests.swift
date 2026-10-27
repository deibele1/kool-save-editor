import Aurora
import Foundation
import Testing

/// Round-trips every GFF and ERF in the real saves on this Mac (read-only). Skipped when
/// no KotOR saves are installed. `KSE_TEST_SAVES` may point at another saves folder.
struct RealSaveRoundTripTests {
    static var savesFolders: [URL] {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        var folders = [
            "Library/Containers/com.aspyr.kotor/Data/Library/Application Support/Knights of the Old Republic/saves",
            "Library/Application Support/Knights of the Old Republic/saves",
            "Library/Application Support/Star Wars Knights of the Old Republic II/saves",
            "Library/Containers/com.aspyr.kotor2.appstore/Data/Library/Application Support/Star Wars Knights of the Old Republic II/saves",
        ].map { home.appendingPathComponent($0) }
        let cloud = home.appendingPathComponent("Library/Application Support/Steam/steamapps/common/Knights of the Old Republic II/cloudsaves")
        folders += ((try? FileManager.default.contentsOfDirectory(at: cloud, includingPropertiesForKeys: nil)) ?? [])
        if let custom = ProcessInfo.processInfo.environment["KSE_TEST_SAVES"] { folders.insert(URL(fileURLWithPath: custom), at: 0) }
        return folders.flatMap { folder in
            ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
                .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("savenfo.res").path) }
        }
    }

    func checkGFF(_ bytes: [UInt8], _ name: String) throws {
        let document = try GFFDocument(bytes: bytes)
        let encoded = document.encoded()
        let decoded = try GFFDocument(bytes: encoded)
        #expect(decoded == document, "\(name) changed after a round trip")
        #expect(decoded.encoded() == encoded, "\(name) encoding is not deterministic")
    }

    @Test func everyGFFAndERFInTheInstalledSavesRoundTrips() throws {
        let saves = Self.savesFolders
        guard !saves.isEmpty else { return }
        var checked = 0
        // A few saves of each game: the list is grouped by folder.
        let sample = Dictionary(grouping: saves) { $0.deletingLastPathComponent() }.values.flatMap { $0.prefix(3) }
        for save in sample {
            for file in try FileManager.default.contentsOfDirectory(atPath: save.path) where file.lowercased().hasSuffix(".res") {
                try checkGFF([UInt8](Data(contentsOf: save.appendingPathComponent(file))), file)
                checked += 1
            }
            let savegame = save.appendingPathComponent("SAVEGAME.sav")
            let original = [UInt8](try Data(contentsOf: savegame))
            let archive = try ERFArchive(bytes: original)
            let reencoded = try ERFArchive(bytes: archive.encoded())
            #expect(reencoded == archive)
            for resource in archive.resources {
                if resource.type == .sav {
                    let inner = try ERFArchive(bytes: resource.data)
                    #expect(try ERFArchive(bytes: inner.encoded()) == inner)
                    for nested in inner.resources where [.ifo, .git, .are].contains(nested.type) {
                        try checkGFF(nested.data, "\(resource.fileName)/\(nested.fileName)")
                        checked += 1
                    }
                } else if [.res, .utc, .fac].contains(resource.type) {
                    try checkGFF(resource.data, resource.fileName)
                    checked += 1
                }
            }
        }
        #expect(checked > 0)
    }
}
