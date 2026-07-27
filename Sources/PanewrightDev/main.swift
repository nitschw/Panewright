import Foundation
import PanewrightCore

// Panewright's command line. Ships inside the app bundle (the cask links it
// into PATH as `panewright`) and doubles as the dev harness when built from
// source as `panewright-dev`:
//   panewright import <i3-config>   — translate a real i3 config to a profile
//   panewright emit [panewright.toml] — print the generated engine config
//   panewright apply                — write config + hot-reload the engine
//   panewright status               — report the tiling engine's health
let arguments = Array(CommandLine.arguments.dropFirst())
// Usage lines name whichever identity was invoked.
let tool = (CommandLine.arguments.first as NSString?)?.lastPathComponent ?? "panewright"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(64)
}

do {
    switch arguments.first {
    case "emit" where arguments.count <= 2:
        let config: PanewrightConfig
        if arguments.count == 2 {
            let toml = try String(contentsOfFile: arguments[1], encoding: .utf8)
            config = try ConfigParser.parse(toml: toml)
        } else {
            config = .default
        }
        print(AeroSpaceConfigEmitter.emit(config), terminator: "")

    case "apply" where arguments.count == 1:
        let orchestrator = Orchestrator()
        if try orchestrator.writeDefaultConfigIfMissing() {
            print("created \(orchestrator.paths.panewrightConfigFile.path)")
        }
        try orchestrator.apply()
        print("applied — AeroSpace \(orchestrator.status())")

    case "status" where arguments.count == 1:
        print("AeroSpace \(Orchestrator().status())")

    case "import" where arguments.count == 2:
        let source = try String(contentsOfFile: arguments[1], encoding: .utf8)
        let result = I3ConfigImporter.importConfig(source)
        let toml = PanewrightConfigSerializer.emit(result.config)
        let orchestrator = Orchestrator()
        try FileManager.default.createDirectory(
            at: orchestrator.profilesDirectory, withIntermediateDirectories: true)
        let destination = orchestrator.profilesDirectory.appending(path: "i3-imported.toml")
        try toml.write(to: destination, atomically: true, encoding: .utf8)
        print(
            "Imported \(result.config.bindings.count) bindings and \(result.config.modes.count) modes"
        )
        print("Saved as profile 'i3-imported' → \(destination.path)")
        print("Activate it from the Panewright menu (Profiles) after reviewing.")
        if result.issues.isEmpty {
            print("\nClean import — nothing needs attention.")
        } else {
            print("\n\(result.issues.count) items need attention:")
            for issue in result.issues {
                print("  line \(issue.line): \(issue.reason)")
                print("    > \(issue.text)")
            }
        }

    default:
        fail("usage: \(tool) import <i3-config> | emit [panewright.toml] | apply | status")
    }
} catch {
    FileHandle.standardError.write(Data("\(tool): \(error)\n".utf8))
    exit(1)
}
