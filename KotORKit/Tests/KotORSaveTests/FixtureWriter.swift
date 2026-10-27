import Foundation
import Testing
import TestFixtures

/// Writes a sample save and game installation for manual UI checks:
/// `KSE_WRITE_FIXTURE=/tmp/kse-fixture swift test --filter FixtureWriter`, then launch the app with
/// `-KSEMacSavesFolder /tmp/kse-fixture/saves -KSEMacGameFolder /tmp/kse-fixture/game`.
struct FixtureWriter {
    @Test func writeSampleSaveWhenRequested() throws {
        guard let path = ProcessInfo.processInfo.environment["KSE_WRITE_FIXTURE"] else { return }
        let root = URL(fileURLWithPath: path)
        try? FileManager.default.removeItem(at: root)
        try SaveFixture.write(to: root.appendingPathComponent("saves/000002 - Game1"), tsl: ProcessInfo.processInfo.environment["KSE_FIXTURE_TSL"] != nil)
        try GameInstallFixture.write(to: root.appendingPathComponent("game"))
    }
}
