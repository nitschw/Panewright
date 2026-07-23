import Foundation
import PanewrightCore

// Dev harness for the orchestration pipeline:
//   panewright-dev emit [panewright.toml]  — print the generated aerospace.toml
//   panewright-dev apply                   — write config + hot-reload AeroSpace
//   panewright-dev status                  — report AeroSpace's health
let arguments = Array(CommandLine.arguments.dropFirst())

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
        fail("usage: panewright-dev emit [panewright.toml] | apply | status | import <i3-config>")
    }
} catch {
    FileHandle.standardError.write(Data("panewright-dev: \(error)\n".utf8))
    exit(1)
}
