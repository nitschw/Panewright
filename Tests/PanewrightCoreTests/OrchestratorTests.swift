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
}
