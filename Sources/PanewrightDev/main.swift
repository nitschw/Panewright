import Foundation
import PanewrightCore

// Dev harness for the config pipeline:
//   panewright-dev emit                     — emit aerospace.toml from defaults
//   panewright-dev emit panewright.toml     — emit from a Panewright config file
let arguments = Array(CommandLine.arguments.dropFirst())

guard arguments.first == "emit", arguments.count <= 2 else {
    FileHandle.standardError.write(Data("usage: panewright-dev emit [panewright.toml]\n".utf8))
    exit(64)
}

do {
    let config: PanewrightConfig
    if arguments.count == 2 {
        let toml = try String(contentsOfFile: arguments[1], encoding: .utf8)
        config = try ConfigParser.parse(toml: toml)
    } else {
        config = .default
    }
    print(AeroSpaceConfigEmitter.emit(config), terminator: "")
} catch {
    FileHandle.standardError.write(Data("panewright-dev: \(error)\n".utf8))
    exit(1)
}
