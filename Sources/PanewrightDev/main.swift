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

    case "menu" where arguments.count <= 2:
        // The dmenu contract: lines in on stdin, the pick out on stdout,
        // exit 1 on dismissal — so `git branch | panewright menu | xargs …`
        // behaves exactly like the rofi/dmenu pipelines it replaces.
        var input = ""
        while let line = readLine(strippingNewline: false) { input += line }
        let items = input.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        guard !items.isEmpty else { exit(1) }
        let session = UUID().uuidString
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "panewright-menu-\(session)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        // Not defer: exit() below never unwinds, and the dismissal path was
        // quietly leaving its temp directory behind on every escape.
        func cleanup() { try? FileManager.default.removeItem(at: directory) }
        let itemsFile = directory.appending(path: "items")
        let replyFifo = directory.appending(path: "reply")
        try items.joined(separator: "\n").write(
            to: itemsFile, atomically: true, encoding: .utf8)
        guard mkfifo(replyFifo.path, 0o600) == 0 else {
            fail("couldn't create the reply pipe")
        }
        var components = URLComponents()
        components.scheme = "panewright"
        components.host = "menu"
        components.queryItems = [
            URLQueryItem(name: "items", value: itemsFile.path),
            URLQueryItem(name: "reply", value: replyFifo.path),
            URLQueryItem(name: "prompt", value: arguments.count == 2 ? arguments[1] : ""),
        ]
        let opener = Process()
        opener.executableURL = URL(filePath: "/usr/bin/open")
        opener.arguments = [components.url!.absoluteString]
        try opener.run()
        opener.waitUntilExit()
        guard opener.terminationStatus == 0 else {
            fail("Panewright isn't running — the menu needs the app for its panel")
        }
        // Block on the pipe like dmenu blocks on X: the answer arrives when
        // the user picks, and an empty answer is a dismissal.
        guard let handle = FileHandle(forReadingAtPath: replyFifo.path) else {
            fail("couldn't open the reply pipe")
        }
        let reply = String(
            decoding: handle.readDataToEndOfFile(), as: UTF8.self
        ).trimmingCharacters(in: .newlines)
        cleanup()
        guard !reply.isEmpty else { exit(1) }
        print(reply)

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
        fail("usage: \(tool) import <i3-config> | menu [prompt] | emit [panewright.toml] | apply | status")
    }
} catch {
    FileHandle.standardError.write(Data("\(tool): \(error)\n".utf8))
    exit(1)
}
