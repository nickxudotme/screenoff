import Foundation
import ScreenOffKit

@MainActor
final class DisplayStore: ObservableObject {
    @Published private(set) var displays: [DisplayItem] = []
    @Published private(set) var disconnectedDisplays: [DisplayItem] = []
    @Published var selectedDisplayID: UInt32?
    @Published var isBusy = false
    @Published var status = "Ready"
    @Published var errorMessage: String?

    private let client: ScreenOffClient

    init() {
        self.client = (try? ScreenOffClient.resolved()) ?? ScreenOffClient(executableURL: URL(fileURLWithPath: "/usr/bin/false"))
    }

    var selectedDisplay: DisplayItem? {
        displays.first { $0.id == selectedDisplayID }
    }

    var selectedDisconnectedDisplay: DisplayItem? {
        disconnectedDisplays.first { $0.id == selectedDisplayID }
    }

    var disconnectedDisplayIDs: [UInt32] {
        disconnectedDisplays.map(\.id)
    }

    private func applyInventory(_ items: [DisplayItem]) {
        displays = items.filter { !($0.state == "disabled" || $0.flags.contains("offline")) }
        disconnectedDisplays = items.filter { $0.state == "disabled" || $0.flags.contains("offline") }
        let selectedStillExists = displays.contains { $0.id == selectedDisplayID }
            || disconnectedDisplays.contains { $0.id == selectedDisplayID }
        if selectedDisplayID == nil || !selectedStillExists {
            selectedDisplayID = displays.first(where: { !$0.isMain })?.id
                ?? disconnectedDisplays.first?.id
                ?? displays.first?.id
        }
    }

    func refresh() async {
        await runBusy(status: "Refreshing displays...") {
            let items = try await client.listDisplays()
            applyInventory(items)
            status = "Found \(displays.count) connected display\(displays.count == 1 ? "" : "s")"
        }
    }

    func disconnect(_ display: DisplayItem) async {
        await runBusy(status: "Disconnecting \(display.displayTitle)...") {
            try await client.disconnect(displayID: display.id)
            try await Task.sleep(nanoseconds: 500_000_000)
            applyInventory(try await client.listDisplays())
            status = "Disconnected \(display.displayTitle)"
        }
    }

    func reconnect(_ display: DisplayItem) async {
        await runBusy(status: "Reconnecting \(display.displayTitle)...") {
            try await client.reconnect(displayID: display.id)
            try await Task.sleep(nanoseconds: 800_000_000)
            applyInventory(try await client.listDisplays())
            selectedDisplayID = display.id
            status = "Reconnected \(display.displayTitle)"
        }
    }

    func reconnectAll() async {
        await runBusy(status: "Reconnecting external displays...") {
            do {
                try await client.reconnectAll()
            } catch {
                // Reconnect-all is intentionally best-effort. Refresh before
                // surfacing any remaining failures so the UI reflects displays
                // that did recover in the same operation.
                applyInventory(try await client.listDisplays())
                throw error
            }
            try await Task.sleep(nanoseconds: 800_000_000)
            applyInventory(try await client.listDisplays())
            status = "Reconnected external displays"
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
}
