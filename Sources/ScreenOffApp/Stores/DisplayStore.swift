import Foundation

@MainActor
final class DisplayStore: ObservableObject {
    @Published private(set) var displays: [DisplayItem] = []
    @Published private(set) var disabledDisplayIDs: [UInt32] = []
    @Published var selectedDisplayID: UInt32?
    @Published var isBusy = false
    @Published var status = "Ready"
    @Published var errorMessage: String?

    private let disabledIDsKey = "disabledDisplayIDs"
    private let client: ScreenOffClient

    init() {
        self.client = (try? ScreenOffClient.resolved()) ?? ScreenOffClient(executableURL: URL(fileURLWithPath: "/usr/bin/false"))
        self.disabledDisplayIDs = Self.loadDisabledIDs(key: disabledIDsKey)
    }

    var selectedDisplay: DisplayItem? {
        displays.first { $0.id == selectedDisplayID }
    }

    var selectedDisabledDisplay: DisabledDisplay? {
        disabledDisplays.first { $0.id == selectedDisplayID }
    }

    var disabledDisplays: [DisabledDisplay] {
        disabledDisplayIDs.map { DisabledDisplay(id: $0) }
    }

    func refresh() async {
        await runBusy(status: "Refreshing displays...") {
            let items = try await client.listDisplays()
            displays = items
            let selectedIsActive = items.contains { $0.id == selectedDisplayID }
            let selectedIsDisabled = disabledDisplayIDs.contains { $0 == selectedDisplayID }
            if selectedDisplayID == nil || (!selectedIsActive && !selectedIsDisabled) {
                selectedDisplayID = items.first(where: { !$0.isMain })?.id ?? items.first?.id
            }
            status = "Found \(items.count) active display\(items.count == 1 ? "" : "s")"
        }
    }

    func disable(_ display: DisplayItem) async {
        await runBusy(status: "Turning off \(display.displayTitle)...") {
            try await client.disable(display: display)
            rememberDisabled(id: display.id)
            selectedDisplayID = display.id
            try await Task.sleep(nanoseconds: 500_000_000)
            let items = try await client.listDisplays()
            displays = items
            status = "Turned off \(display.displayTitle)"
        }
    }

    func restore(_ disabledDisplay: DisabledDisplay) async {
        await restore(id: disabledDisplay.id)
    }

    func restore(id: UInt32) async {
        await runBusy(status: "Restoring Display \(id)...") {
            try await client.restore(displayID: id)
            forgetDisabled(id: id)
            try await Task.sleep(nanoseconds: 800_000_000)
            displays = try await client.listDisplays()
            selectedDisplayID = id
            status = "Restored Display \(id)"
        }
    }

    func restoreAllDisabled() async {
        let ids = disabledDisplayIDs
        for id in ids {
            await restore(id: id)
        }
    }

    private func runBusy(status newStatus: String, operation: () async throws -> Void) async {
        isBusy = true
        status = newStatus
        errorMessage = nil
        do {
            try await operation()
        } catch {
            errorMessage = error.localizedDescription
            status = "Needs attention"
        }
        isBusy = false
    }

    private func rememberDisabled(id: UInt32) {
        if !disabledDisplayIDs.contains(id) {
            disabledDisplayIDs.append(id)
            saveDisabledIDs()
        }
    }

    private func forgetDisabled(id: UInt32) {
        disabledDisplayIDs.removeAll { $0 == id }
        saveDisabledIDs()
    }

    private func saveDisabledIDs() {
        let value = disabledDisplayIDs.map(String.init).joined(separator: ",")
        UserDefaults.standard.set(value, forKey: disabledIDsKey)
    }

    private static func loadDisabledIDs(key: String) -> [UInt32] {
        let raw = UserDefaults.standard.string(forKey: key) ?? ""
        return raw.split(separator: ",").compactMap { UInt32($0) }
    }
}
