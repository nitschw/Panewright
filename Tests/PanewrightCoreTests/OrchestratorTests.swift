import Foundation
import Testing

@testable import PanewrightCore

@Suite struct OrchestratorTests {
    private func makeOrchestrator() -> (Orchestrator, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "panewright-tests-\(UUID().uuidString)")
        let paths = PanewrightPaths(
            panewrightConfigFile: dir.appending(path: "panewright/panewright.toml"),
            aerospaceConfigFile: dir.appending(path: "aerospace/aerospace.toml"),
            sketchybarConfigDirectory: dir.appending(path: "sketchybar"))
        return (Orchestrator(paths: paths), dir)
    }

    @Test func writesDefaultConfigExactlyOnce() throws {
        let (orchestrator, dir) = makeOrchestrator()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try orchestrator.writeDefaultConfigIfMissing() == true)
        #expect(try orchestrator.writeDefaultConfigIfMissing() == false)
    }

    @Test func defaultTemplateParsesToDefaultConfig() throws {
        let config = try ConfigParser.parse(toml: Orchestrator.defaultConfigTemplate)
        #expect(config == .default)
    }

    @Test func stallCheckIgnoresAnEmptyDesktop() {
        // Too few on-screen windows to distinguish a stall from a genuinely
        // empty desktop — never cry wolf (and never touch the CLI).
        let (orchestrator, dir) = makeOrchestrator()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(orchestrator.aeroSpaceIsStalled(visibleAppWindowCount: 0) == false)
        #expect(
            orchestrator.aeroSpaceIsStalled(
                visibleAppWindowCount: Orchestrator.stallWindowThreshold - 1) == false)
    }

    @Test func missingConfigFileLoadsDefaults() throws {
        let (orchestrator, dir) = makeOrchestrator()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try orchestrator.loadConfig() == .default)
    }

    @Test func malformedConfigFileIsAnError() throws {
        let (orchestrator, dir) = makeOrchestrator()
        defer { try? FileManager.default.removeItem(at: dir) }
        try orchestrator.writeDefaultConfigIfMissing()
        try "modifier = \"super\"\n".write(
            to: orchestrator.paths.panewrightConfigFile, atomically: true, encoding: .utf8)
        #expect(throws: ConfigError.invalidModifier("super")) {
            try orchestrator.loadConfig()
        }
    }

    @Test func togglingBordersEditsExistingSectionPreservingComments() {
        let toml = """
            # my config
            [border]
            width = 6  # chunky
            enabled = true
            """
        let result = Orchestrator.settingEnabled(false, section: "border", in: toml)
        #expect(result.contains("enabled = false"))
        #expect(result.contains("# my config"))
        #expect(result.contains("width = 6  # chunky"))
        #expect(!result.contains("enabled = true"))
    }

    @Test func togglingBordersInsertsIntoSectionWithoutFlag() {
        let toml = """
            [border]
            width = 6

            [gaps]
            inner = 8
            """
        let result = Orchestrator.settingEnabled(false, section: "border", in: toml)
        #expect(result.contains("[border]\nenabled = false\nwidth = 6"))
        #expect(result.contains("[gaps]"))
    }

    @Test func togglingBordersAppendsSectionWhenMissing() throws {
        let result = Orchestrator.settingEnabled(false, section: "border", in: "modifier = \"alt\"\n")
        #expect(result.contains("[border]\nenabled = false"))
        let config = try ConfigParser.parse(toml: result)
        #expect(config.focusBorder.enabled == false)
    }

    @Test func writeConfigRoundTripsThroughParser() throws {
        let (orchestrator, dir) = makeOrchestrator()
        defer { try? FileManager.default.removeItem(at: dir) }
        var config = PanewrightConfig.default
        config.gaps.inner = 17
        config.focusBorder.activeColor = "#FF375F"
        try orchestrator.writeConfig(config)
        #expect(try orchestrator.loadConfig() == config)
    }

    @Test func profilesSaveListAndValidateOnActivate() throws {
        let (orchestrator, dir) = makeOrchestrator()
        defer { try? FileManager.default.removeItem(at: dir) }
        try orchestrator.writeDefaultConfigIfMissing()
        #expect(orchestrator.listProfiles().isEmpty)
        try orchestrator.saveProfile(named: "work")
        try orchestrator.saveProfile(named: "demo rice")
        #expect(orchestrator.listProfiles() == ["demo rice", "work"])
        // Corrupt a profile: activation must refuse before clobbering.
        try "modifier = \"bogus\"\n".write(
            to: orchestrator.profilesDirectory.appending(path: "work.toml"),
            atomically: true, encoding: .utf8)
        #expect(throws: ConfigError.invalidModifier("bogus")) {
            try orchestrator.activateProfile(named: "work")
        }
        let live = try String(
            contentsOf: orchestrator.paths.panewrightConfigFile, encoding: .utf8)
        #expect(!live.contains("bogus"))
    }

    @Test func rejectsBadProfileNames() {
        let (orchestrator, dir) = makeOrchestrator()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: ConfigError.invalidProfileName("../evil")) {
            try orchestrator.saveProfile(named: "../evil")
        }
        #expect(throws: ConfigError.invalidProfileName("  ")) {
            try orchestrator.saveProfile(named: "  ")
        }
    }

    @Test func writeAerospaceConfigRunsFullPipeline() throws {
        let (orchestrator, dir) = makeOrchestrator()
        defer { try? FileManager.default.removeItem(at: dir) }
        try orchestrator.writeDefaultConfigIfMissing()
        let emitted = try orchestrator.writeAerospaceConfig()
        #expect(emitted.contains("[mode.main.binding]"))
        let onDisk = try String(
            contentsOf: orchestrator.paths.aerospaceConfigFile, encoding: .utf8)
        #expect(onDisk == emitted)
    }
}

@Suite struct ConfigWatcherTests {
    @Test func firesAfterFileChange() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "panewright-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try await confirmation { changed in
            let watcher = ConfigWatcher(directory: dir) { changed() }
            try watcher.start()
            try "modifier = \"alt\"\n".write(
                to: dir.appending(path: "panewright.toml"), atomically: true, encoding: .utf8)
            try await Task.sleep(for: .milliseconds(800))
            watcher.stop()
        }
    }

    /// The app watches with a `file:`, which turns on the modification-date
    /// gate and the polling fallback — neither of which the test above
    /// touches, since without a file every directory event fires directly.
    ///
    /// And it changes the file *twice*. One change was detected correctly even
    /// when the mechanism was broken, because the bug was a stale cached read:
    /// the first comparison had nothing cached yet. Only the second edit
    /// exposed it, which is precisely why the app went months re-applying
    /// nothing while this suite stayed green.
    @Test func firesOnEverySuccessiveChangeNotJustTheFirst() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "panewright-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "panewright.toml")
        try "modifier = \"alt\"\n".write(to: file, atomically: true, encoding: .utf8)

        try await confirmation(expectedCount: 2) { changed in
            let watcher = ConfigWatcher(directory: dir, file: file) { changed() }
            try watcher.start()
            try "modifier = \"cmd\"\n".write(to: file, atomically: true, encoding: .utf8)
            try await Task.sleep(for: .milliseconds(900))
            try "modifier = \"ctrl\"\n".write(to: file, atomically: true, encoding: .utf8)
            try await Task.sleep(for: .milliseconds(900))
            watcher.stop()
        }
    }
}

/// Profiles are saved configs, so losing or silently overwriting one loses
/// work that can't be reconstructed.
@Suite struct ProfileManagementTests {
    private func orchestrator() throws -> (Orchestrator, URL) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "panewright-profiles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = PanewrightPaths(
            panewrightConfigFile: root.appending(path: "panewright.toml"),
            aerospaceConfigFile: root.appending(path: "aerospace.toml"),
            sketchybarConfigDirectory: root.appending(path: "sketchybar"))
        return (Orchestrator(paths: paths), root)
    }

    @Test func aProfileCanBeSavedListedAndDeleted() throws {
        let (orchestrator, root) = try orchestrator()
        defer { try? FileManager.default.removeItem(at: root) }
        try orchestrator.saveProfile(named: "work")
        #expect(orchestrator.listProfiles() == ["work"])
        try orchestrator.deleteProfile(named: "work")
        #expect(orchestrator.listProfiles().isEmpty)
    }

    @Test func renamingKeepsTheProfileAndDropsTheOldName() throws {
        let (orchestrator, root) = try orchestrator()
        defer { try? FileManager.default.removeItem(at: root) }
        try orchestrator.saveProfile(named: "work")
        try orchestrator.renameProfile(from: "work", to: "office")
        #expect(orchestrator.listProfiles() == ["office"])
    }

    @Test func renamingOverAnExistingProfileIsRefused() throws {
        // Silently replacing a saved config with a different one isn't a
        // rename, it's losing the other profile.
        let (orchestrator, root) = try orchestrator()
        defer { try? FileManager.default.removeItem(at: root) }
        try orchestrator.saveProfile(named: "work")
        try orchestrator.saveProfile(named: "home")
        #expect(throws: (any Error).self) {
            try orchestrator.renameProfile(from: "work", to: "home")
        }
        #expect(orchestrator.listProfiles() == ["home", "work"])
    }

    @Test func namesThatEscapeTheProfilesDirectoryAreRefused() throws {
        let (orchestrator, root) = try orchestrator()
        defer { try? FileManager.default.removeItem(at: root) }
        try orchestrator.saveProfile(named: "work")
        // "../panewright" would delete the live config rather than a profile.
        #expect(throws: (any Error).self) {
            try orchestrator.deleteProfile(named: "../panewright")
        }
        #expect(throws: (any Error).self) { try orchestrator.deleteProfile(named: "  ") }
    }
}
