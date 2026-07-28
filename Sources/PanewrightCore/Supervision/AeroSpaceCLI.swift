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

    private struct SocketRequest: Encodable {
        let args: [String]
        let stdin: String
    }

    private struct SocketAnswer: Decodable {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    /// The engine's own wire protocol, spoken directly: a unix socket at
    /// /tmp/bobko.aerospace-<user>.sock, 4-byte native-endian length prefix,
    /// JSON request and answer — exactly what the aerospace CLI binary does,
    /// minus the process launch.
    ///
    /// The launch is the point. Every CLI call used to exec a binary, and on
    /// managed machines endpoint security taxes each exec (hundreds of ms) —
    /// and one day escalated to DENYING them outright (ES_AUTH_RESULT_DENY),
    /// at which point every strip, probe and command in the system died at
    /// the exec gate while nothing of ours was at fault. A socket write from
    /// an already-running, already-trusted process cannot be exec-denied,
    /// and costs microseconds.
    private func runViaSocket(_ arguments: [String], timeout: TimeInterval) throws -> String {
        let path = "/tmp/bobko.aerospace-\(NSUserName()).sock"
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw TransportError.socket }
        defer { close(fd) }
        var tv = timeval(
            tv_sec: Int(timeout), tv_usec: Int32((timeout.truncatingRemainder(dividingBy: 1)) * 1e6))
        _ = withUnsafePointer(to: &tv) {
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
        }
        _ = withUnsafePointer(to: &tv) {
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        withUnsafeMutablePointer(to: &addr.sun_path) { pathPointer in
            path.withCString { cPath in
                _ = strlcpy(
                    UnsafeMutableRawPointer(pathPointer).assumingMemoryBound(to: CChar.self),
                    cPath, capacity)
            }
        }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw TransportError.connect }

        let payload = try JSONEncoder().encode(SocketRequest(args: arguments, stdin: ""))
        var frame = withUnsafeBytes(of: UInt32(payload.count)) { Data($0) }
        frame.append(payload)
        try frame.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            var sent = 0
            while sent < buffer.count {
                let n = write(fd, buffer.baseAddress!.advanced(by: sent), buffer.count - sent)
                guard n > 0 else { throw TransportError.write }
                sent += n
            }
        }

        func readExactly(_ count: Int) throws -> Data {
            var data = Data(count: count)
            var received = 0
            try data.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
                while received < count {
                    let n = read(fd, buffer.baseAddress!.advanced(by: received), count - received)
                    guard n > 0 else { throw TransportError.read }
                    received += n
                }
            }
            return data
        }
        let length = try readExactly(4).withUnsafeBytes { $0.load(as: UInt32.self) }
        guard length < 16_000_000 else { throw TransportError.read }
        let answer = try JSONDecoder().decode(SocketAnswer.self, from: readExactly(Int(length)))
        guard answer.exitCode == 0 else {
            throw AeroSpaceCLIError(
                arguments: arguments, exitCode: answer.exitCode,
                output: answer.stdout + answer.stderr)
        }
        return answer.stdout
    }

    private enum TransportError: Error { case socket, connect, write, read }

    /// Bounded: a CLI call that hangs — the engine's socket half-dead
    /// mid-teardown answers connects and then says nothing — used to block
    /// its caller forever. Called from the main thread, that was the
    /// minutes-long beachball during an update. No child gets more than the
    /// timeout; a timeout is an error, never a hang.
    @discardableResult
    public func run(_ arguments: [String], timeout: TimeInterval = 5) throws -> String {
        // Socket first; the exec path survives only as the fallback for the
        // window before the engine's server is listening. A command the
        // *server* rejected is a real error and must not be retried by exec.
        do {
            return try runViaSocket(arguments, timeout: timeout)
        } catch let error as AeroSpaceCLIError {
            throw error
        } catch {
            // Transport failure — engine not up yet, or socket mid-restart.
        }
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if exited.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 1)
            }
        }
        // Read after exit (the child is gone, so this drains and EOFs), and
        // close the handles explicitly — thousands of CLI calls a day must
        // not lean on deallocation timing for their file descriptors.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        try? pipe.fileHandleForReading.close()
        try? pipe.fileHandleForWriting.close()
        let output = String(decoding: data, as: UTF8.self)
        guard !timedOut else {
            throw AeroSpaceCLIError(
                arguments: arguments, exitCode: -1,
                output: "timed out after \(Int(timeout))s")
        }
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
