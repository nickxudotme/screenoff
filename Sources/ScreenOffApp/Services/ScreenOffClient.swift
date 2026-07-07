import Foundation
import ScreenOffKit

struct CommandResult {
    let data: Data
    let status: Int32

    var output: String {
        String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

struct ScreenOffClient {
    let executableURL: URL

    static func resolved() throws -> ScreenOffClient {
        let bundleResource = Bundle.main.resourceURL?.appendingPathComponent("screenoff")
        if let bundleResource, FileManager.default.isExecutableFile(atPath: bundleResource.path) {
            return ScreenOffClient(executableURL: bundleResource)
        }

        let currentExecutable = URL(fileURLWithPath: CommandLine.arguments[0])
        let sibling = currentExecutable.deletingLastPathComponent().appendingPathComponent("screenoff")
        if FileManager.default.isExecutableFile(atPath: sibling.path) {
            return ScreenOffClient(executableURL: sibling)
        }

        throw ScreenOffError.missingCLI
    }

    func listDisplays() async throws -> [DisplayItem] {
        let result = try run(["list", "--json"])
        guard result.status == 0 else {
            throw ScreenOffError.commandFailed(result.output)
        }

        do {
            return try DisplayParser.parseJSON(result.data)
        } catch {
            return result.output
                .split(separator: "\n")
                .compactMap { DisplayParser.parseLegacyLine(String($0)) }
        }
    }

    func disable(display: DisplayItem, backend: DisplayBackend) async throws {
        let result = try run(["off", "#\(display.index)", "--backend", backend.rawValue])
        guard result.status == 0 else {
            throw ScreenOffError.commandFailed(result.output)
        }
    }

    func restore(displayID: UInt32, backend: DisplayBackend) async throws {
        let result = try run(["on", "\(displayID)", "--backend", backend.rawValue])
        guard result.status == 0 else {
            throw ScreenOffError.commandFailed(result.output)
        }
    }

    private func run(_ arguments: [String]) throws -> CommandResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return CommandResult(data: data, status: process.terminationStatus)
    }
}

enum ScreenOffError: LocalizedError {
    case missingCLI
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingCLI:
            return "Could not find the screenoff command line tool inside the app bundle."
        case .commandFailed(let output):
            return output.isEmpty ? "The command failed without output." : output
        }
    }
}
