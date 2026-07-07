import Foundation

struct DisplayItem: Identifiable, Hashable {
    let index: Int
    let id: UInt32
    let name: String
    let state: String
    let geometry: String
    let flags: [String]

    var isMain: Bool {
        flags.contains("main")
    }

    var isBuiltIn: Bool {
        flags.contains("built-in")
    }

    var displayTitle: String {
        name.isEmpty ? "Display \(id)" : name
    }
}

struct DisabledDisplay: Identifiable, Hashable {
    let id: UInt32

    var title: String {
        "Display \(id)"
    }
}
