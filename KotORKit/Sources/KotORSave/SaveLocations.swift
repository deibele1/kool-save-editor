// KSEMac — a KotOR savegame editor for macOS.
// Finds the Mac App Store and Steam save folders and game data of the Aspyr ports.

import Aurora
import Foundation

public struct SaveLocation: Hashable, Codable, Sendable, Identifiable {
    public enum Source: String, Codable, Sendable {
        case steam
        case appStore
        case steamCloud
        case custom
    }

    public var game: Game
    public var source: Source
    public var url: URL
    public var detail: String?

    public init(game: Game, source: Source, url: URL, detail: String? = nil) {
        self.game = game
        self.source = source
        self.url = url.standardizedFileURL
        self.detail = detail
    }

    public var id: String { url.path }

    public var sourceTitle: String {
        switch source {
        case .steam: "Steam"
        case .appStore: "Mac App Store"
        case .steamCloud: detail.map { "Steam Cloud (\($0))" } ?? "Steam Cloud"
        case .custom: url.lastPathComponent
        }
    }
}

public enum SaveDiscovery {
    struct Candidate {
        var game: Game
        var source: SaveLocation.Source
        var path: String
    }

    static let kotor1Folders = ["Knights of the Old Republic", "KOTOR"]
    static let kotor2Folder = "Star Wars Knights of the Old Republic II"
    static let kotor1Containers = ["com.aspyr.kotor", "com.aspyr.kotor.appstore"]
    static let kotor2Containers = ["com.aspyr.kotor2.appstore", "com.aspyr.kotor2"]

    /// Save folders of the Steam and Mac App Store releases that exist on this Mac.
    public static func defaultLocations(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [SaveLocation] {
        let support = "Library/Application Support"
        var candidates: [Candidate] = []
        for folder in kotor1Folders {
            candidates.append(Candidate(game: .kotor1, source: .steam, path: "\(support)/\(folder)/saves"))
        }
        for container in kotor1Containers {
            for folder in kotor1Folders {
                candidates.append(Candidate(game: .kotor1, source: .appStore,
                                            path: "Library/Containers/\(container)/Data/\(support)/\(folder)/saves"))
            }
        }
        candidates.append(Candidate(game: .kotor2, source: .steam, path: "\(support)/\(kotor2Folder)/saves"))
        for container in kotor2Containers {
            candidates.append(Candidate(game: .kotor2, source: .appStore,
                                        path: "Library/Containers/\(container)/Data/\(support)/\(kotor2Folder)/saves"))
        }

        let fm = FileManager.default
        var seen = Set<String>()
        var locations: [SaveLocation] = []
        for candidate in candidates {
            let url = home.appendingPathComponent(candidate.path)
            guard let resolved = existingDirectory(url), seen.insert(resolved.path.lowercased()).inserted else { continue }
            locations.append(SaveLocation(game: candidate.game, source: candidate.source, url: resolved))
        }

        // With "Use Steam Cloud=1" the Steam release writes to cloudsaves/<account>/ in the game's
        // install folder (next to KOTOR2.app), as KSE expected; also check beside the local saves.
        var cloudRoots = [(Game.kotor2, home.appendingPathComponent("\(support)/\(kotor2Folder)/cloudsaves"))]
        for library in steamLibraries(home: home) {
            for game in Game.allCases {
                for folder in steamInstallFolders(for: game) {
                    cloudRoots.append((game, library.appendingPathComponent("steamapps/common/\(folder)/cloudsaves")))
                }
            }
        }
        for (game, root) in cloudRoots {
            guard let users = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                          options: [.skipsHiddenFiles]) else { continue }
            for user in users.sorted(by: { $0.path < $1.path }) where isDirectory(user) {
                guard seen.insert(user.standardizedFileURL.path.lowercased()).inserted else { continue }
                locations.append(SaveLocation(game: game, source: .steamCloud, url: user, detail: user.lastPathComponent))
            }
        }
        return locations
    }

    /// Folder names of the Steam installs under steamapps/common.
    static func steamInstallFolders(for game: Game) -> [String] {
        game == .kotor1 ? ["swkotor", "Star Wars Knights of the Old Republic"] : ["Knights of the Old Republic II"]
    }

    /// Save game directories (those containing `savenfo.res`) inside a saves folder.
    public static func saveFolders(in location: URL) -> [URL] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: location, includingPropertiesForKeys: [.isDirectoryKey],
                                                      options: [.skipsHiddenFiles]) else { return [] }
        return items.filter { isDirectory($0) && fm.caseInsensitiveItem(named: "savenfo.res", in: $0) != nil }
    }

    /// Folders that look like a game installation (they contain `chitin.key`), found in the
    /// Steam libraries and installed applications.
    public static func gameDataCandidates(for game: Game, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                          applicationFolders: [URL]? = nil) -> [URL] {
        var roots: [URL] = []
        for library in steamLibraries(home: home) {
            for folder in steamInstallFolders(for: game) {
                roots.append(library.appendingPathComponent("steamapps/common/\(folder)"))
            }
        }
        let names = game == .kotor1 ? ["knights of the old republic", "kotor", "swkotor"] : ["kotor 2", "kotor2", "old republic ii", "sith lords"]
        let folders = applicationFolders ?? [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]
        for applications in folders {
            let apps = (try? FileManager.default.contentsOfDirectory(at: applications, includingPropertiesForKeys: nil)) ?? []
            for app in apps where app.pathExtension == "app" {
                let name = app.deletingPathExtension().lastPathComponent.lowercased()
                let matches = names.contains { name.contains($0) }
                let isOtherGame = game == .kotor1 && (name.contains("ii") || name.contains("2"))
                if matches && !isOtherGame { roots.append(app) }
            }
        }

        var found: [URL] = []
        for root in roots {
            if let data = findGameData(in: root, depth: 4), !found.contains(data) { found.append(data) }
        }
        return found
    }

    public static func isGameData(_ url: URL) -> Bool {
        FileManager.default.caseInsensitiveItem(named: "chitin.key", in: url) != nil
    }

    /// Breadth-first search for the directory holding `chitin.key`.
    public static func findGameData(in root: URL, depth: Int) -> URL? {
        var level = [root]
        for _ in 0 ... depth {
            var next: [URL] = []
            for directory in level {
                if isGameData(directory) { return directory.standardizedFileURL }
                let children = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey],
                                                                            options: [.skipsHiddenFiles])) ?? []
                next += children.filter { isDirectory($0) && !skippedFolders.contains($0.lastPathComponent.lowercased()) }
            }
            level = next
        }
        return nil
    }

    static let skippedFolders: Set<String> = [
        "movies", "streammusic", "streamsounds", "streamwaves", "streamvoice", "lips", "texturepacks", "modules",
        "frameworks", "plugins", "_codesignature", "saves", "override", "data", "rims",
    ]

    static func steamLibraries(home: URL) -> [URL] {
        let steam = home.appendingPathComponent("Library/Application Support/Steam")
        var libraries = [steam]
        let vdf = steam.appendingPathComponent("steamapps/libraryfolders.vdf")
        if let text = try? String(contentsOf: vdf, encoding: .utf8) {
            // Every quoted token in order; the token after each "path" key is a library folder.
            let tokens = text.split(separator: "\"", omittingEmptySubsequences: false).enumerated()
                .filter { $0.offset % 2 == 1 }.map { String($0.element) }
            for (index, token) in tokens.enumerated() where token.lowercased() == "path" && index + 1 < tokens.count {
                let url = URL(fileURLWithPath: tokens[index + 1].replacingOccurrences(of: "\\\\", with: "\\"))
                if !libraries.contains(url) { libraries.append(url) }
            }
        }
        return libraries
    }

    static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// The directory at `url`, matched case-insensitively at the last component.
    static func existingDirectory(_ url: URL) -> URL? {
        if isDirectory(url) { return url.standardizedFileURL }
        let parent = url.deletingLastPathComponent()
        guard let match = FileManager.default.caseInsensitiveItem(named: url.lastPathComponent, in: parent), isDirectory(match) else {
            return nil
        }
        return match.standardizedFileURL
    }
}
