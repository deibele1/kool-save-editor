import AppKit
import KotORSave
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager
    @State private var visibility = NavigationSplitViewVisibility.all
    @State private var titleBarHeight: CGFloat = 0
    @State private var sidebarEdge: CGFloat = 0

    var body: some View {
        NavigationSplitView(columnVisibility: $visibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 250, ideal: 290, max: 420)
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxX } action: { sidebarEdge = $0 }
        } content: {
            Group {
                if let document = model.selectedDocument {
                    OutlineView(document: document)
                } else {
                    ContentUnavailableView("No Save Selected", systemImage: "externaldrive",
                                           description: Text("Choose a savegame in the sidebar."))
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
        } detail: {
            Group {
                if let document = model.selectedDocument {
                    // One view per save: a field being typed in goes away with its save and
                    // applies its text there (see CommitTextField).
                    DetailView(document: document).id(document.id)
                } else {
                    Image(systemName: "shield.lefthalf.filled")
                        .font(.system(size: 64))
                        .foregroundStyle(.quaternary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .overlay(alignment: .topLeading) {
            // An opaque, two-toned bar across the whole top: nothing scrolls under the window
            // buttons or the save name, and the column dividers don't run through the title.
            HStack(spacing: 0) {
                Color.titleBarSidebar.frame(width: visibility == .all ? sidebarEdge : 0)
                Color.titleBarMain
            }
            .frame(height: titleBarHeight)
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
        .background(TitleBarHeightReader(height: $titleBarHeight))
        .onChange(of: model.selectedSaveID, initial: true) { old, _ in
            if let old, let previous = model.documents[old] {
                undoManager?.removeAllActions(withTarget: previous)
                previous.undoManager = nil
            }
            model.selectedDocument?.undoManager = undoManager
        }
        .alert("Something Went Wrong", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        // Revert and Reload from the toolbar, the menus and the save list all ask here. The
        // save is named because a save-list target may not be the one on screen.
        .confirmationDialog(discardTitle, isPresented: Binding(get: { model.pendingDiscard != nil }, set: { if !$0 { model.pendingDiscard = nil } }),
                            titleVisibility: .visible, presenting: model.pendingDiscard) { request in
            Button(request.action == .revert ? "Revert" : "Reload", role: .destructive) { model.discard(request) }
            Button("Cancel", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: { request in
            Text(request.action == .revert
                ? "Your unsaved changes (\(request.document.changeSummary)) will be discarded. You can’t undo this."
                : "Your unsaved changes (\(request.document.changeSummary)) will be discarded and the save read again from disk. You can’t undo this.")
        }
        .confirmationDialog(pasteTitle, isPresented: Binding(get: { model.pendingPaste != nil }, set: { if !$0 { model.pendingPaste = nil } }),
                            titleVisibility: .visible, presenting: model.pendingPaste) { document in
            Button("Replace Inventory", role: .destructive) { model.pasteInventory(into: document) }
            Button("Cancel", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: { document in
            Text(pasteMessage(document))
        }
    }

    private var discardTitle: String {
        guard let request = model.pendingDiscard else { return "" }
        let name = request.document.summary.name
        return request.action == .revert ? "Revert “\(name)” to the saved version?" : "Reload “\(name)” from disk?"
    }

    private var pasteTitle: String {
        model.pendingPaste.map { "Replace the inventory of “\($0.summary.name)”?" } ?? ""
    }

    private func pasteMessage(_ document: SaveDocument) -> String {
        func items(_ count: Int) -> String { count == 1 ? "1 item" : "\(count) items" }
        let current = document.save?.inventoryItems.count ?? 0
        let copied = model.inventoryClipboard?.items.count ?? 0
        let source = model.inventoryClipboard?.sourceName ?? ""
        let pasted = copied == 1 ? "the item copied from “\(source)”" : "the \(copied) items copied from “\(source)”"
        var message = switch (current, copied) {
        case (0, 0): "It has no items, and neither does the inventory copied from “\(source)”."
        case (0, _): "It has no items; \(pasted) will be added."
        case (_, 0): "Its \(items(current)) will be removed: the inventory copied from “\(source)” is empty."
        default: "Its \(items(current)) will be replaced by \(pasted)."
        }
        let quests = model.questItemsLostByPasting(into: document)
        if quests > 0 {
            message += " That removes \(quests == 1 ? "a quest item" : "\(quests) quest items") the copied inventory doesn’t have, which quests may need."
        }
        return message + " You can undo this or revert before saving."
    }

    private var title: String { model.selectedDocument?.summary.name ?? "Kool Save Editor" }

    private var subtitle: String {
        guard let document = model.selectedDocument else { return "Choose a savegame" }
        var parts = [document.game.title]
        if !document.summary.area.isEmpty { parts.append(document.summary.area) }
        if document.isDirty { parts.append("Edited") }
        return parts.joined(separator: " · ")
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if let document = model.selectedDocument {
                // Not the Undo arrow (arrow.uturn.backward): this discards every edit.
                Button {
                    model.requestRevert(document)
                } label: {
                    Label("Revert to Saved", systemImage: "arrow.counterclockwise")
                }
                .help("Revert to Saved: discard all unsaved changes to this save")
                .disabled(!model.hasUnsavedChanges(document) || document.isSaving)

                Button {
                    model.commitTyping()
                    Task { await document.commit(using: model) }
                } label: {
                    if document.isSaving {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Save", systemImage: "square.and.arrow.down")
                    }
                }
                .help(model.isGameRunning(document.game)
                    ? "Quit \(document.game.title) before saving: it would overwrite the changes"
                    : "Write the changes to the save (a backup version is kept)")
                .disabled(!model.hasUnsavedChanges(document) || document.isSaving || model.isGameRunning(document.game))
            }
        }
    }
}

/// Reports the height of the window's title bar and toolbar (the window's height above its
/// content layout rect), which SwiftUI doesn't expose as a safe area in split view columns.
struct TitleBarHeightReader: NSViewRepresentable {
    @Binding var height: CGFloat

    func makeNSView(context: Context) -> NSView { ReaderView(height: $height) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class ReaderView: NSView {
        let height: Binding<CGFloat>
        private var observers: [NSObjectProtocol] = []

        init(height: Binding<CGFloat>) {
            self.height = height
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            for name in [NSWindow.didResizeNotification, NSWindow.didEnterFullScreenNotification,
                         NSWindow.didExitFullScreenNotification, NSWindow.didBecomeKeyNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.measure() }
                })
            }
            measure()
        }

        private func measure() {
            guard let window, let content = window.contentView else { return }
            let value = max(0, content.bounds.height - window.contentLayoutRect.height)
            if abs(value - height.wrappedValue) > 0.5 {
                DispatchQueue.main.async { self.height.wrappedValue = value }
            }
        }
    }
}

extension Color {
    /// The title bar is two-toned: gray above the save list, the dark window color above the
    /// outline and detail where the save name sits.
    static let titleBarSidebar = Color(nsColor: NSColor(name: nil) { appearance in
        let gray: CGFloat = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 0.255 : 0.84
        return NSColor(srgbRed: gray, green: gray, blue: gray, alpha: 1)
    })
    static let titleBarMain = Color(nsColor: .windowBackgroundColor)
}

// MARK: - Sidebar

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selectedSaveID) {
            ForEach(model.locations) { location in
                Section {
                    let state = model.locationStates[location.id] ?? LocationState()
                    if let error = state.error {
                        HStack(spacing: 6) {
                            Label(error, systemImage: "lock.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .help(state.errorHelp ?? error)
                            if let help = state.errorHelp {
                                LocationHelpButton(location: location, help: help, isBlockedByPrivacy: state.isBlockedByPrivacy)
                            }
                        }
                        .selectionDisabled()
                    } else if state.summaries.isEmpty, !state.isLoading {
                        Text("No saves").foregroundStyle(.tertiary).selectionDisabled()
                    }
                    ForEach(state.summaries) { summary in
                        SaveRow(summary: summary, isEdited: model.documents[summary.id]?.isDirty == true)
                            .tag(summary.id)
                            .contextMenu { SaveContextMenu(summary: summary) }
                    }
                } header: {
                    LocationHeader(location: location)
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if model.locations.isEmpty {
                ContentUnavailableView {
                    Label("No Saves Found", systemImage: "externaldrive.badge.questionmark")
                } description: {
                    Text("Kool Save Editor looks in the Mac App Store and Steam save folders of both games.")
                } actions: {
                    Button("Add Saves Folder…") { model.chooseCustomFolder() }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Button { model.chooseCustomFolder() } label: { Image(systemName: "plus") }
                    .help("Add a saves folder")
                Spacer()
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh the save list")
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
    }
}

/// The ? button next to a folder that can't be read. It opens a sheet rather than a popover,
/// so the steps stay on screen while the user is in System Settings.
struct LocationHelpButton: View {
    let location: SaveLocation
    let help: String
    let isBlockedByPrivacy: Bool

    @State private var isShowing = false

    var body: some View {
        HelpLink { isShowing = true }
            .controlSize(.small)
            .sheet(isPresented: $isShowing) {
                FolderAccessSheet(location: location, help: help, isBlockedByPrivacy: isBlockedByPrivacy)
            }
    }
}

struct FolderAccessSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let location: SaveLocation
    let help: String
    let isBlockedByPrivacy: Bool

    /// The game as System Settings lists it under Files & Folders.
    private var gameName: String {
        location.game == .kotor1 ? "Knights of the Old Republic" : "Knights of the Old Republic II"
    }

    /// macOS 27 lists access to other apps' data per app under Files & Folders (confirmed on
    /// macOS 27); for earlier versions the steps use Full Disk Access, which works on all of them.
    private var usesFilesAndFolders: Bool {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0))
    }

    private var settingsURL: URL? {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?" + (usesFilesAndFolders ? "Privacy_FilesAndFolders" : "Privacy_AllFiles"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(isBlockedByPrivacy ? "Allow Access to the Mac App Store Saves" : "Can’t Read This Folder", systemImage: "lock.fill")
                .font(.headline)
            if isBlockedByPrivacy {
                Text("macOS keeps apps out of other apps’ data unless you allow it, and the Mac App Store games keep their saves in their own data.")
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 8) {
                    if usesFilesAndFolders {
                        step(1, "Click Open Files & Folders. It opens System Settings › Privacy & Security › Files & Folders.")
                        step(2, "Under Kool Save Editor, turn on \(gameName).")
                    } else {
                        step(1, "Click Open Full Disk Access. It opens System Settings › Privacy & Security › Full Disk Access.")
                        step(2, "Turn on Kool Save Editor. If it isn’t listed, click + and choose it in Applications.")
                    }
                    step(3, "Come back and click Quit & Reopen: macOS applies the change when Kool Save Editor starts again.")
                }
            } else {
                Text(help).fixedSize(horizontal: false, vertical: true)
                Text(location.url.path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
            HStack {
                if isBlockedByPrivacy {
                    Button(usesFilesAndFolders ? "Open Files & Folders" : "Open Full Disk Access") {
                        if let settingsURL { NSWorkspace.shared.open(settingsURL) }
                    }
                    Button("Quit & Reopen") {
                        AppDelegate.relaunchesAfterQuit = true
                        dismiss()
                        // AppKit refuses to quit (and beeps) while a sheet is open.
                        Task {
                            try? await Task.sleep(for: .milliseconds(400))
                            NSApp.terminate(nil)
                        }
                    }
                } else {
                    Button("Refresh") {
                        model.refresh()
                        dismiss()
                    }
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(width: 460)
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number).").monospacedDigit().foregroundStyle(.secondary)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct LocationHeader: View {
    @Environment(AppModel.self) private var model
    let location: SaveLocation

    var body: some View {
        HStack(spacing: 4) {
            Text(location.game.shortTitle)
            Text("· \(location.sourceTitle)").foregroundStyle(.secondary)
            Spacer()
            if location.source == .custom {
                Button { model.removeCustomFolder(location) } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
                    .help("Stop showing this folder")
            }
        }
    }
}

struct SaveRow: View {
    @Environment(AppModel.self) private var model
    let summary: SaveSummary
    let isEdited: Bool

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let image = model.thumbnails[summary.id] {
                    Image(nsImage: image).resizable()
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            .frame(width: 64, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.separator))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(summary.name).font(.headline).lineLimit(1)
                    if isEdited {
                        Circle().fill(.secondary).frame(width: 6, height: 6).help("Unsaved changes")
                    }
                }
                if !summary.area.isEmpty {
                    Text(summary.area).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Text("\(summary.modified.formatted(.relative(presentation: .named))) · \(Duration.seconds(summary.timePlayed).playTime)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
        .task { model.loadThumbnail(for: summary) }
    }
}

struct SaveContextMenu: View {
    @Environment(AppModel.self) private var model
    let summary: SaveSummary

    var body: some View {
        let document = model.documents[summary.id]
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([summary.folder]) }
        Button("Reload from Disk") {
            if let document { model.requestReload(document) } else { model.selectedSaveID = summary.id }
        }
        Divider()
        Button("Copy Inventory") {
            model.selectedSaveID = summary.id
            if let document = model.documents[summary.id], document.isReady { model.copyInventory(from: document) }
        }
        .disabled(!(document?.isReady ?? false))
        Button("Paste Inventory…") {
            if let document { model.requestPasteInventory(into: document) }
        }
        .disabled(!model.canPasteInventory(into: document))
        Divider()
        Button("Show Versions") {
            model.selectedSaveID = summary.id
            model.documents[summary.id]?.section = .versions
        }
    }
}

// MARK: - Outline

struct OutlineView: View {
    @Environment(AppModel.self) private var model
    @Bindable var document: SaveDocument

    var body: some View {
        switch document.state {
        case .loading:
            ProgressView("Loading Save…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label("Can’t Open This Save", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { model.requestReload(document) }
                Button("Show Versions") { document.section = .versions }
            }
        case .ready:
            ScrollViewReader { proxy in
                List(selection: $document.section) {
                    Section("Savegame") {
                        row("Summary", "info.circle", .summary)
                    }
                    Section("Characters") {
                        row(document.playerTitle, "person.crop.circle.fill", .character(.player))
                        ForEach(document.save?.companionIndices ?? [], id: \.self) { index in
                            row(document.name(of: .npc(index)), "person.crop.circle", .character(.npc(index)))
                        }
                    }
                    Section("Party") {
                        row("Party & Resources", "person.3", .party)
                        row("Inventory", "shippingbox", .inventory)
                    }
                    Section("World") {
                        row("Journal", "book.closed", .journal)
                        row("Global Variables", "globe", .globals)
                    }
                    Section("History") {
                        row("Versions", "clock.arrow.circlepath", .versions)
                    }
                }
                .listStyle(.sidebar)
                .onChange(of: document.section) { _, section in
                    guard let section else { return }
                    withAnimation { proxy.scrollTo(section) }
                }
            }
        }
    }

    private func row(_ title: String, _ symbol: String, _ section: SaveSection) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: symbol).foregroundStyle(.tint)
        }
        .tag(section)
        .id(section)
    }
}

// MARK: - Detail

struct DetailView: View {
    @Environment(AppModel.self) private var model
    @Bindable var document: SaveDocument

    var body: some View {
        VStack(spacing: 0) {
            // Not fixed-size: wrapping text with a fixed size above a table broke the window's layout.
            if model.isGameRunning(document.game) {
                GameRunningNotice(game: document.game)
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
            }
            Group {
                if case .ready = document.state, document.save != nil {
                    switch document.section ?? .summary {
                    case .summary: SummaryView(document: document)
                    case .character(let character): CharacterView(document: document, character: character).id(character)
                    case .party: PartyView(document: document)
                    case .inventory: InventoryView(document: document)
                    case .journal: JournalView(document: document)
                    case .globals: GlobalsView(document: document)
                    case .versions: VersionsView(document: document)
                    }
                } else if document.section == .versions {
                    VersionsView(document: document)
                } else {
                    Color.clear
                }
            }
        }
        .alert("The Save Changed on Disk", isPresented: Binding(get: { document.externalChanges != nil }, set: { if !$0 { document.externalChanges = nil } })) {
            // Saving waits until the game has quit, as the toolbar's Save does.
            if !model.isGameRunning(document.game) {
                Button("Replace with My Version", role: .destructive) {
                    document.externalChanges = nil
                    Task { await document.commit(using: model, overwriteExternalChanges: true) }
                }
            }
            Button("Reload and Discard Edits") {
                document.externalChanges = nil
                document.reload(using: model)
            }
            Button("Cancel", role: .cancel) { document.externalChanges = nil }
                .keyboardShortcut(.defaultAction)
        } message: {
            let replacing = model.isGameRunning(document.game)
                ? "Once \(document.game.title) has quit, you can replace it with your version."
                : "Replace with My Version writes the whole save as you see it here, edits included, in place of the newer one. The newer save is kept in Versions first, so you can restore it."
            Text("\((document.externalChanges ?? []).joined(separator: ", ")) changed outside the editor, perhaps because the game saved over this save. \(replacing)")
        }
        .alert("Couldn’t Save", isPresented: Binding(get: { document.errorMessage != nil }, set: { if !$0 { document.errorMessage = nil } })) {
            Button("OK") { document.errorMessage = nil }
        } message: {
            Text(document.errorMessage ?? "")
        }
    }
}
