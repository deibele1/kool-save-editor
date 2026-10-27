import Foundation
import KotORSave

/// User settings, stored as JSON in the user defaults.
struct Preferences: Codable, Equatable {
    struct CustomFolder: Codable, Equatable, Hashable {
        var path: String
        var game: Game
    }

    var gameFolders: [String: String] = [:]
    var customFolders: [CustomFolder] = []
    var versionRetention = 25
    var showAllAbilities = false
    var encodingID: String?

    func gameFolder(for game: Game) -> URL? {
        gameFolders[game.rawValue].map { URL(fileURLWithPath: $0) }
    }

    mutating func setGameFolder(_ url: URL?, for game: Game) {
        gameFolders[game.rawValue] = url?.path
    }

    private static let key = "Preferences"

    static func load(from defaults: UserDefaults = .standard) -> Preferences {
        guard let data = defaults.data(forKey: key), let value = try? JSONDecoder().decode(Preferences.self, from: data) else {
            return Preferences()
        }
        return value
    }

    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }
}
