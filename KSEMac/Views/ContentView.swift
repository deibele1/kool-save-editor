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
                    DetailView(document: document)
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
                Button {
                    document.revert()
                } label: {
                    Label("Revert", systemImage: "arrow.uturn.backward")
                }
                .help("Discard unsaved changes")
                .disabled(!document.isDirty || document.isSaving)

                Button {
                    Task { await document.commit(using: model) }
                } label: {
                    if document.isSaving {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Save", systemImage: "square.and.arrow.down")
                    }
                }
                .help("Write the changes to the save (a backup version is kept)")
                .disabled(!document.isDirty || document.isSaving)
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
                        Label(error, systemImage: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
            if let document { document.reload(using: model) } else { model.selectedSaveID = summary.id }
        }
        Divider()
        Button("Copy Inventory") {
            model.selectedSaveID = summary.id
            if let document = model.documents[summary.id], document.isReady { model.copyInventory(from: document) }
        }
        .disabled(!(document?.isReady ?? false))
        Button("Paste Inventory") {
            if let document { model.pasteInventory(into: document) }
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
                Button("Try Again") { document.reload(using: model) }
                Button("Show Versions") { document.section = .versions }
            }
        case .ready:
            ScrollViewReader { proxy in
                List(selection: $document.section) {
                    Section("Savegame") {
                        row("Summary", "info.circle", .summary)
                    }
                    Section("Characters") {
                        row(document.name(of: .player), "person.crop.circle.fill", .character(.player))
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
        .alert("The Save Changed on Disk", isPresented: Binding(get: { document.externalChanges != nil }, set: { if !$0 { document.externalChanges = nil } })) {
            Button("Save Anyway", role: .destructive) {
                document.externalChanges = nil
                Task { await document.commit(using: model, overwriteExternalChanges: true) }
            }
            Button("Reload and Discard Edits") {
                document.externalChanges = nil
                document.reload(using: model)
            }
            Button("Cancel", role: .cancel) { document.externalChanges = nil }
        } message: {
            Text("\((document.externalChanges ?? []).joined(separator: ", ")) changed since the save was opened, perhaps because the game saved over it. Saving now replaces those changes; the current files are kept as a version either way.")
        }
        .alert("Couldn’t Save", isPresented: Binding(get: { document.errorMessage != nil }, set: { if !$0 { document.errorMessage = nil } })) {
            Button("OK") { document.errorMessage = nil }
        } message: {
            Text(document.errorMessage ?? "")
        }
    }
}
