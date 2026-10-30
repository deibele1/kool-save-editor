import AppKit
import KotORSave
import SwiftUI

@main
struct KSEMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Kool Save Editor", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 980, minHeight: 620)
                .onAppear { appDelegate.model = model }
        }
        .defaultSize(width: 1280, height: 800)
        .commands { EditorCommands(model: model) }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    /// Set by Quit & Reopen: a privacy setting changed while the app runs only reaches a new
    /// process, so a fresh copy is started once this one has quit.
    static var relaunchesAfterQuit = false

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        guard Self.relaunchesAfterQuit else { return }
        // Waits for this process to exit, then opens the app again.
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "while /bin/kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\"",
                              Bundle.main.bundlePath]
        try? relaunch.run()
    }

    /// Set while the app is in the background; on returning, saves the game wrote meanwhile are read again.
    private var wasInactive = false

    func applicationDidResignActive(_ notification: Notification) {
        wasInactive = true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard wasInactive else { return }
        wasInactive = false
        model?.refresh()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // A name still being typed counts as an unsaved change.
        model?.commitTyping()
        guard let model, !model.dirtyDocuments.isEmpty else { return .terminateNow }
        let count = model.dirtyDocuments.count
        let alert = NSAlert()
        // A running game's saves can't be written (it would overwrite them); the other game's still
        // can. The editor stays open by default, so they can be saved once the game has quit.
        let blocked = model.dirtyDocuments.filter { model.isGameRunning($0.game) }
        if !blocked.isEmpty {
            let others = model.dirtyDocuments.filter { !model.isGameRunning($0.game) }
            let running = Set(blocked.map(\.game)).count == 1 ? "\(blocked[0].game.title) is" : "Both games are"
            let changes = blocked.count == 1 ? "the changes you made to “\(blocked[0].summary.name)”" : "your changes in \(blocked.count) saves"
            alert.messageText = "\(running) running, so \(changes) can’t be saved."
            alert.informativeText = GameRunningError.advice + (others.isEmpty
                ? " Your changes will be lost if you don’t save them."
                : " Your other changes can still be saved, but \(changes) will be lost if you quit now.")
            alert.addButton(withTitle: "Cancel")
            if !others.isEmpty { alert.addButton(withTitle: "Save Others and Quit") }
            alert.addButton(withTitle: "Don’t Save")
            switch alert.runModal() {
            case .alertSecondButtonReturn where !others.isEmpty:
                return quitAfterSaving(others, model: model, sender: sender)
            case .alertSecondButtonReturn, .alertThirdButtonReturn:  // Don’t Save
                return .terminateNow
            default:
                Self.relaunchesAfterQuit = false
                return .terminateCancel
            }
        }
        alert.messageText = count == 1
            ? "Do you want to save the changes you made to “\(model.dirtyDocuments[0].summary.name)”?"
            : "You have unsaved changes in \(count) saves. Do you want to save them?"
        alert.informativeText = "Your changes will be lost if you don’t save them."
        alert.addButton(withTitle: count == 1 ? "Save" : "Save All")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don’t Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return quitAfterSaving(model: model, sender: sender)
        case .alertThirdButtonReturn:
            return .terminateNow
        default:
            Self.relaunchesAfterQuit = false
            return .terminateCancel
        }
    }

    /// Quits once `documents` (every edited save by default) are saved, or stays open if one of
    /// them couldn't be.
    private func quitAfterSaving(_ documents: [SaveDocument]? = nil, model: AppModel,
                                 sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            let saved = await model.saveAll(documents)
            if !saved { Self.relaunchesAfterQuit = false }
            sender.reply(toApplicationShouldTerminate: saved)
        }
        return .terminateLater
    }
}

struct EditorCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Kool Save Editor") { AboutPanel.show() }
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") {
                guard let document = model.selectedDocument else { return }
                model.commitTyping()
                Task { await document.commit(using: model) }
            }
            .keyboardShortcut("s")
            .disabled(!(model.selectedDocument.map { model.hasUnsavedChanges($0) && !$0.isSaving && !model.isGameRunning($0.game) } ?? false))

            Button("Revert to Saved") {
                if let document = model.selectedDocument { model.requestRevert(document) }
            }
            .disabled(!model.hasUnsavedChanges(model.selectedDocument) || model.selectedDocument?.isSaving == true)
        }
        CommandGroup(replacing: .newItem) {
            Button("Add Saves Folder…") { model.chooseCustomFolder() }
                .keyboardShortcut("o")
        }
        CommandMenu("Savegame") {
            // The harmless refresh gets ⌘R; reloading can discard edits (it asks first).
            Button("Reload from Disk") {
                if let document = model.selectedDocument { model.requestReload(document) }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(model.selectedDocument == nil)

            Button("Refresh Save List") { model.refresh() }
                .keyboardShortcut("r")

            Divider()

            Button("Copy Inventory") {
                if let document = model.selectedDocument { model.copyInventory(from: document) }
            }
            .disabled(!(model.selectedDocument?.isReady ?? false))

            Button("Paste Inventory…") {
                if let document = model.selectedDocument { model.requestPasteInventory(into: document) }
            }
            .disabled(!model.canPasteInventory(into: model.selectedDocument))

            Divider()

            Button("Show Versions") { model.selectedDocument?.section = .versions }
                .keyboardShortcut("y", modifiers: [.command, .option])
                .disabled(model.selectedDocument == nil)

            Button("Show in Finder") {
                if let folder = model.selectedDocument?.summary.folder {
                    NSWorkspace.shared.activateFileViewerSelecting([folder])
                }
            }
            .disabled(model.selectedDocument == nil)
        }
        CommandGroup(replacing: .help) {
            Link("KotOR Savegame Editor (Windows) on DeadlyStream",
                 destination: URL(string: "https://deadlystream.com/files/file/503-kotor-savegame-editor/")!)
            Link("xoreos Project", destination: URL(string: "https://xoreos.org/")!)
        }
    }
}
