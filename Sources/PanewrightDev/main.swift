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

    default:
        fail("usage: panewright-dev emit [panewright.toml] | apply | status")
    }
} catch {
    FileHandle.standardError.write(Data("panewright-dev: \(error)\n".utf8))
    exit(1)
}
