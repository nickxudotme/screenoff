import Foundation

public enum DisplayBackend: String, CaseIterable, Codable, Identifiable, Sendable {
    case auto
    case coregraphics
    case ddc
    case m1ddc

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .auto:
            return "Auto"
        case .coregraphics:
            return "CoreGraphics"
        case .ddc:
            return "DDC/CI"
        case .m1ddc:
            return "m1ddc"
        }
    }
}

public struct DisplayItem: Identifiable, Hashable, Codable, Sendable {
    public let index: Int
    public let id: UInt32
    public let name: String
    public let state: String
    public let geometry: String
    public let flags: [String]

    public init(index: Int, id: UInt32, name: String, state: String, geometry: String, flags: [String]) {
        self.index = index
        self.id = id
        self.name = name
        self.state = state
        self.geometry = geometry
        self.flags = flags
    }

    public var isMain: Bool {
        flags.contains("main")
    }

    public var isBuiltIn: Bool {
        flags.contains("built-in")
    }

    public var displayTitle: String {
        name.isEmpty ? "Display \(id)" : name
    }
}

public struct DisabledDisplay: Identifiable, Hashable, Sendable {
    public let id: UInt32

    public init(id: UInt32) {
        self.id = id
    }

    public var title: String {
        "Display \(id)"
    }
}

public struct DisabledDisplayRecord: Identifiable, Hashable, Codable, Sendable {
    public let id: UInt32
    public var name: String
    public var backend: DisplayBackend
    public var disabledAt: Date

    public init(id: UInt32, name: String, backend: DisplayBackend, disabledAt: Date) {
        self.id = id
        self.name = name
        self.backend = backend
        self.disabledAt = disabledAt
    }

    public var title: String {
        name.isEmpty ? "Display \(id)" : name
    }
}

public enum DisplayParser {
    public static func parseJSON(_ data: Data) throws -> [DisplayItem] {
        try JSONDecoder().decode([DisplayItem].self, from: data)
    }

    public static func parseLegacyLine(_ line: String) -> DisplayItem? {
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
