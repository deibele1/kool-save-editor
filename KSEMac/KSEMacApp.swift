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

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, !model.dirtyDocuments.isEmpty else { return .terminateNow }
        let count = model.dirtyDocuments.count
        let alert = NSAlert()
        alert.messageText = count == 1
            ? "Do you want to save the changes you made to “\(model.dirtyDocuments[0].summary.name)”?"
            : "You have unsaved changes in \(count) saves. Do you want to save them?"
        alert.informativeText = "Your changes will be lost if you don’t save them."
        alert.addButton(withTitle: count == 1 ? "Save" : "Save All")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don’t Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Task { @MainActor in
                let saved = await model.saveAll()
                if !saved { Self.relaunchesAfterQuit = false }
                sender.reply(toApplicationShouldTerminate: saved)
            }
            return .terminateLater
        case .alertThirdButtonReturn:
            return .terminateNow
        default:
            Self.relaunchesAfterQuit = false
            return .terminateCancel
        }
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
                Task { await document.commit(using: model) }
            }
            .keyboardShortcut("s")
            .disabled(!(model.selectedDocument?.isDirty ?? false))

            Button("Revert to Saved") { model.selectedDocument?.revert() }
                .disabled(!(model.selectedDocument?.isDirty ?? false))
        }
        CommandGroup(replacing: .newItem) {
            Button("Add Saves Folder…") { model.chooseCustomFolder() }
                .keyboardShortcut("o")
        }
        CommandMenu("Savegame") {
            Button("Reload from Disk") {
                if let document = model.selectedDocument { document.reload(using: model) }
            }
            .keyboardShortcut("r")
            .disabled(model.selectedDocument == nil)

            Button("Refresh Save List") { model.refresh() }
                .keyboardShortcut("r", modifiers: [.command, .shift])

            Divider()

            Button("Copy Inventory") {
                if let document = model.selectedDocument { model.copyInventory(from: document) }
            }
            .disabled(!(model.selectedDocument?.isReady ?? false))

            Button("Paste Inventory") {
                if let document = model.selectedDocument { model.pasteInventory(into: document) }
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
