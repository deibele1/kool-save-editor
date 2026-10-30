import AppKit
import KotORSave
import SwiftUI

/// The save's history, oldest first: the original save, each version kept before a save or
/// restore, and the save as it is now.
struct VersionsView: View {
    @Environment(AppModel.self) private var model
    let document: SaveDocument

    @State private var selection: String?
    @State private var restoring: SaveVersion?
    @State private var deleting: SaveVersion?

    struct Row: Identifiable {
        var id: String
        var title: String
        var changes: String
        var date: Date?
        var size: Int?
        var timePlayed: Int?
        /// Game time played since the previous row (negative after restoring an older version).
        var played: Int?
        var version: SaveVersion?
        var isFirst = false
    }

    private var rows: [Row] {
        let versions = Array(document.versions.reversed())
        let deltas = versions.playTimeDeltas()
        var rows = versions.enumerated().map { index, version in
            Row(id: version.id, title: version.title, changes: version.changes ?? "", date: version.savedDate,
                size: version.totalSize, timePlayed: version.timePlayed, played: deltas[index], version: version,
                isFirst: index == 0)
        }
        if let current = document.currentState {
            let played = current.timePlayed.flatMap { now in versions.last?.timePlayed.map { now - $0 } }
            rows.append(Row(id: "current", title: "Current save", changes: current.changes, date: current.modified,
                            size: current.size, timePlayed: current.timePlayed, played: played, version: nil))
        }
        return rows
    }

    var body: some View {
        let rows = rows
        let selected = rows.first { $0.id == selection }?.version
        // No fixed-size wrapping text above the table: in a split-view detail column it broke
        // layout of the whole window (blank sidebars, empty rows).
        VStack(alignment: .leading, spacing: 10) {
            Table(rows, selection: $selection) {
                TableColumn("Version") { row in
                    HStack(spacing: 8) {
                        Image(systemName: symbol(for: row))
                            .foregroundStyle(row.version == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                            .frame(width: 18)
                        Text(row.title)
                            .fontWeight(row.version == nil || row.version?.isOriginal == true ? .semibold : .regular)
                    }
                }
                .width(min: 100, ideal: 115, max: 140)
                TableColumn("Changes") { row in
                    Text(row.changes)
                        .foregroundStyle(row.changes == SaveVersion.noChanges ? .secondary : .primary)
                        .help(row.changes)
                }
                TableColumn("Played") { row in
                    Text(Self.playedText(row))
                        .foregroundStyle(row.played == 0 || (row.played == nil && !row.isFirst) ? .secondary : .primary)
                        .monospacedDigit()
                        .help(playedHelp(row))
                }
                .width(min: 60, ideal: 75, max: 90)
                TableColumn("Saved") { row in
                    Text(row.date.map(Self.shortDate) ?? "")
                        .foregroundStyle(.secondary)
                        .help(row.date?.formatted(date: .complete, time: .standard) ?? "")
                }
                .width(min: 110, ideal: 120, max: 135)
                TableColumn("Size") { row in
                    Text(row.size.map { Int64($0).formatted(.byteCount(style: .file)) } ?? "")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .width(min: 55, ideal: 65, max: 75)
            }
            .contextMenu(forSelectionType: String.self) { ids in
                if let version = rows.first(where: { ids.contains($0.id) })?.version {
                    Button("Restore This Version…") { restoring = version }
                        .disabled(isGameRunning)
                    Button("Show in Finder") { reveal(version) }
                    Divider()
                    Button("Delete Version…", role: .destructive) { deleting = version }
                }
            } primaryAction: { ids in
                if !isGameRunning { restoring = rows.first { ids.contains($0.id) }?.version }
            }
            .overlay {
                if rows.isEmpty {
                    ContentUnavailableView("No Versions Yet", systemImage: "clock.arrow.circlepath",
                                           description: Text("The original save is kept the first time you save changes to it."))
                }
            }
            HStack {
                Button("Restore…") { restoring = selected }
                    .disabled(selected == nil || isGameRunning)
                    .help(isGameRunning ? "Quit \(document.game.title) before restoring: it would overwrite the save" : "")
                Button("Show in Finder") { if let selected { reveal(selected) } }
                    .disabled(selected == nil)
                Button("Delete…", role: .destructive) { deleting = selected }
                    .disabled(selected == nil)
                Spacer()
                Button("Open Versions Folder") {
                    let folder = model.versionStore.folder(for: document.summary.folder)
                    NSWorkspace.shared.open(FileManager.default.fileExists(atPath: folder.path) ? folder : model.versionStore.root)
                }
            }
            Text("Restore “Original” to undo every change made with Kool Save Editor. A version is kept before each save or restore, so a restore can be undone too. The original and the newest \(model.preferences.versionRetention) versions are kept.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .onAppear { document.refreshVersions(using: model) }
        .confirmationDialog(restoring.map { "Restore “\($0.title)”?" } ?? "",
                            isPresented: Binding(get: { restoring != nil }, set: { if !$0 { restoring = nil } }),
                            presenting: restoring) { version in
            Button("Restore") { document.restore(version, using: model) }
        } message: { version in
            let changes = version.changes.map { $0 == SaveVersion.noChanges ? "" : " (\($0))" } ?? ""
            let player = model.versionStore.restoreKeepsCurrentPlayer(version, to: document.summary.folder)
                ? " This version was kept before Kool Save Editor backed up pifo.ifo, so the restored autosave keeps the character it has now." : ""
            Text("The save goes back to \(version.title)\(changes), saved \(version.savedDate.formatted(date: .abbreviated, time: .shortened)).\(player) The current save is kept as a new version first, so you can switch back\(document.isDirty ? ", but unsaved edits are discarded" : "").")
        }
        .confirmationDialog(deleting.map { "Delete “\($0.title)”?" } ?? "",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            presenting: deleting) { version in
            Button("Delete Version", role: .destructive) { document.delete(version, using: model) }
        } message: { version in
            Text(version.isOriginal
                ? "Without the original, changes made with Kool Save Editor can no longer be undone all at once."
                : "This version can no longer be restored.")
        }
    }

    /// Restoring writes the save, which waits until its game has quit.
    private var isGameRunning: Bool { model.isGameRunning(document.game) }

    static func shortDate(_ date: Date) -> String {
        let thisYear = Calendar.current.isDate(date, equalTo: .now, toGranularity: .year)
        let style = Date.FormatStyle.dateTime.month(.abbreviated).day().hour().minute()
        return date.formatted(thisYear ? style : style.year())
    }

    /// The first version shows its total play time; later rows show the play time gained
    /// since the row before, always signed.
    static func playedText(_ row: Row) -> String {
        if let played = row.played {
            return (played < 0 ? "−" : "+") + Duration.seconds(abs(played)).playTime
        }
        guard row.isFirst, let total = row.timePlayed else { return "—" }
        return Duration.seconds(total).playTime
    }

    private func playedHelp(_ row: Row) -> String {
        let total = row.timePlayed.map { "\(Duration.seconds($0).playTime) of play time in total." } ?? ""
        guard let played = row.played else { return total }
        if played < 0 { return "Goes back \(Duration.seconds(-played).playTime) of play time. \(total)" }
        return "Played \(Duration.seconds(played).playTime) since the previous version. \(total)"
    }

    private func symbol(for row: Row) -> String {
        if row.version?.isOriginal == true { return "flag" }
        if row.version == nil { return "checkmark.circle" }
        if row.changes.localizedCaseInsensitiveContains(SaveVersion.externalChanges) || row.changes.hasSuffix("then played") {
            return "gamecontroller"
        }
        if row.changes.hasPrefix("Restored") { return "arrow.uturn.backward" }
        return "pencil"
    }

    private func reveal(_ version: SaveVersion) {
        NSWorkspace.shared.activateFileViewerSelecting([model.versionStore.location(of: version, for: document.summary.folder)])
    }
}
