import AppKit
import KotORSave
import Observation

/// Which games are running, from NSWorkspace's running applications and its launch and quit
/// notifications (no polling). A running game keeps its own copy of the save it loaded and
/// writes it back when it saves (quicksave, autosave or a save over the slot), replacing
/// anything written there meanwhile, so the editor doesn't write that game's saves until it quits.
@Observable
final class GameMonitor {
    private(set) var running: Set<Game> = []
    /// Called when games quit: they may have saved over the slots.
    @ObservationIgnored var didQuit: (@MainActor (Set<Game>) -> Void)?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var listObservation: NSKeyValueObservation?

    init() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            let launched = name == NSWorkspace.didLaunchApplicationNotification
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                MainActor.assumeIsolated { self?.update(app, launched: launched) }
            })
        }
        // The notifications skip background and UI-element processes; the list changes for every one.
        listObservation = NSWorkspace.shared.observe(\.runningApplications) { [weak self] _, _ in
            Task { @MainActor in self?.update() }
        }
        update()
    }

    func isRunning(_ game: Game) -> Bool { running.contains(game) }

    /// Rebuilds the set from every running application rather than from the one that changed:
    /// a game's launcher starts the engine as a second process of the same bundle, so one of
    /// them quitting doesn't mean the game has.
    private func update(_ changed: NSRunningApplication? = nil, launched: Bool = false) {
        var apps = NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }
        if let changed {
            // The list may not reflect the notification yet.
            apps.removeAll { $0.processIdentifier == changed.processIdentifier }
            if launched { apps.append(changed) }
        }
        let now = Set(apps.compactMap { $0.bundleIdentifier.flatMap(Game.init(bundleIdentifier:)) })
        guard now != running else { return }
        let quit = running.subtracting(now)
        running = now
        if !quit.isEmpty { didQuit?(quit) }
    }

    /// Asks macOS directly instead of reading `running`: the check right before writing, which
    /// runs off the main actor and catches a game started since the window last updated.
    nonisolated static func checkNotRunning(_ game: Game, restoring: Bool = false) throws {
        let isRunning = NSWorkspace.shared.runningApplications.contains { app in
            !app.isTerminated && app.bundleIdentifier.flatMap(Game.init(bundleIdentifier:)) == game
        }
        if isRunning { throw GameRunningError(game: game, isRestore: restoring) }
    }
}

/// Why a save of a running game isn't written.
nonisolated struct GameRunningError: LocalizedError {
    var game: Game
    /// Restoring a version rather than saving edits.
    var isRestore = false

    static let advice = "Quit the game before saving: it keeps its own copy of the save it loaded and will overwrite your changes."

    var errorDescription: String? {
        let advice = isRestore
            ? "Quit the game before restoring: it keeps its own copy of the save it loaded and will overwrite the restored version."
            : Self.advice
        return "\(game.title) is running. \(advice)"
    }
}
