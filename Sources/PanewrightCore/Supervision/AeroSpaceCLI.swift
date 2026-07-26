import Foundation

public struct AeroSpaceCLIError: Error, CustomStringConvertible {
    public let arguments: [String]
    public let exitCode: Int32
    public let output: String

    public var description: String {
        "aerospace \(arguments.joined(separator: " ")) exited \(exitCode): \(output)"
    }
}

/// Thin wrapper around the `aerospace` command-line tool — Panewright's entire
/// control surface for the tiling engine.
public struct AeroSpaceCLI: Sendable {
    public let executableURL: URL

    public init(executableURL: URL) {
        self.executableURL = executableURL
    }

    /// The bundled CLI first: when the engine ships inside Panewright, the
    /// CLI beside it is version-locked to that engine, while whatever brew
    /// linked may be older, newer, or stock. Falling back to the brew paths
    /// keeps a bundle-less dev build working.
    public static var defaultSearchPaths: [String] {
        [
            Bundle.main.bundleURL
                .appending(path: "Contents/Helpers/aerospace-cli").path,
            "/opt/homebrew/bin/aerospace",
            "/usr/local/bin/aerospace",
        ]
    }

    public static func locate(fileManager: FileManager = .default) -> AeroSpaceCLI? {
        for path in defaultSearchPaths where fileManager.isExecutableFile(atPath: path) {
            return AeroSpaceCLI(executableURL: URL(filePath: path))
        }
        return nil
    }

    @discardableResult
    public func run(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw AeroSpaceCLIError(
                arguments: arguments,
                exitCode: process.terminationStatus,
                output: output
            )
        }
        return output
    }
}
