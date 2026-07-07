import Foundation

struct CommandResult {
    let output: String
    let status: Int32
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
        let result = try run(["list"])
        guard result.status == 0 else {
            throw ScreenOffError.commandFailed(result.output)
        }
        return result.output
            .split(separator: "\n")
            .compactMap { DisplayParser.parse(String($0)) }
    }

    func disable(display: DisplayItem) async throws {
        let result = try run(["off", "#\(display.index)", "--backend", "coregraphics"])
        guard result.status == 0 else {
            throw ScreenOffError.commandFailed(result.output)
        }
    }

    func restore(displayID: UInt32) async throws {
        let result = try run(["on", "\(displayID)", "--backend", "coregraphics"])
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
        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return CommandResult(output: output, status: process.terminationStatus)
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

enum DisplayParser {
    static func parse(_ line: String) -> DisplayItem? {
        let tokens = line.split(separator: " ", maxSplits: 4).map(String.init)
        guard tokens.count == 5,
              tokens[0].hasPrefix("#"),
              let index = Int(tokens[0].dropFirst()),
              tokens[1].hasPrefix("id="),
              let id = UInt32(tokens[1].dropFirst(3)) else {
            return nil
        }

        let state = tokens[2]
        let geometry = tokens[3]
        let remainder = tokens[4]

        let knownFlagSets = [
            "main, built-in, online",
            "main, built-in, offline",
            "built-in, online",
            "built-in, offline",
            "main, online",
            "main, offline",
            "online",
            "offline"
        ]

        for flagText in knownFlagSets {
            if remainder.hasPrefix(flagText) {
                let name = remainder.dropFirst(flagText.count).trimmingCharacters(in: .whitespaces)
                let flags = flagText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                return DisplayItem(index: index, id: id, name: name, state: state, geometry: geometry, flags: flags)
            }
        }

        return DisplayItem(index: index, id: id, name: remainder, state: state, geometry: geometry, flags: [])
    }
}
