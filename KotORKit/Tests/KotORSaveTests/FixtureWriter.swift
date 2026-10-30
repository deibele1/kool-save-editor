import Foundation
import Testing
import TestFixtures

/// Writes a sample save and game installation for manual UI checks:
/// `KSE_WRITE_FIXTURE=/tmp/kse-fixture swift test --filter FixtureWriter`, then launch the app with
/// `-KSEMacSavesFolder /tmp/kse-fixture/saves -KSEMacGameFolder /tmp/kse-fixture/game`.
/// `KSE_FIXTURE_COPIES=1` adds a transition autosave with Bastila standing in the area and a
/// save made while playing as Carth, whose sheets say the game uses other copies.
struct FixtureWriter {
    @Test func writeSampleSaveWhenRequested() throws {
        guard let path = ProcessInfo.processInfo.environment["KSE_WRITE_FIXTURE"] else { return }
        let root = URL(fileURLWithPath: path)
        let tsl = ProcessInfo.processInfo.environment["KSE_FIXTURE_TSL"] != nil
        try? FileManager.default.removeItem(at: root)
        try SaveFixture.write(to: root.appendingPathComponent("saves/000002 - Game1"), tsl: tsl)
        if ProcessInfo.processInfo.environment["KSE_FIXTURE_COPIES"] != nil {
            try SaveFixture.write(to: root.appendingPathComponent("saves/000001 - AUTOSAVE"), tsl: tsl, pcAutosave: true, inArea: [0])
            try SaveFixture.write(to: root.appendingPathComponent("saves/000003 - Game2"), tsl: tsl, controlling: 2)
        }
        try GameInstallFixture.write(to: root.appendingPathComponent("game"))
    }
}
