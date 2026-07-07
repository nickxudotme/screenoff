import Foundation
import ScreenOffKit

@MainActor
final class DisplayStore: ObservableObject {
    @Published private(set) var displays: [DisplayItem] = []
    @Published private(set) var disabledDisplayRecords: [DisabledDisplayRecord] = []
    @Published var selectedDisplayID: UInt32?
    @Published var isBusy = false
    @Published var status = "Ready"
    @Published var errorMessage: String?
    @Published var selectedBackend: DisplayBackend = .auto

    private let disabledRecordsKey = "disabledDisplayRecords"
    private let legacyDisabledIDsKey = "disabledDisplayIDs"
    private let client: ScreenOffClient

    init() {
        self.client = (try? ScreenOffClient.resolved()) ?? ScreenOffClient(executableURL: URL(fileURLWithPath: "/usr/bin/false"))
        self.disabledDisplayRecords = Self.loadDisabledRecords(recordsKey: disabledRecordsKey, legacyIDsKey: legacyDisabledIDsKey)
    }

    var selectedDisplay: DisplayItem? {
        displays.first { $0.id == selectedDisplayID }
    }

    var selectedDisabledDisplay: DisabledDisplayRecord? {
        disabledDisplayRecords.first { $0.id == selectedDisplayID }
    }

    var disabledDisplayIDs: [UInt32] {
        disabledDisplayRecords.map(\.id)
    }

    func refresh() async {
        await runBusy(status: "Refreshing displays...") {
            let items = try await client.listDisplays()
            displays = items
            let selectedIsActive = items.contains { $0.id == selectedDisplayID }
            let selectedIsDisabled = disabledDisplayRecords.contains { $0.id == selectedDisplayID }
            if selectedDisplayID == nil || (!selectedIsActive && !selectedIsDisabled) {
                selectedDisplayID = items.first(where: { !$0.isMain })?.id ?? items.first?.id
            }
            status = "Found \(items.count) active display\(items.count == 1 ? "" : "s")"
        }
    }

    func disable(_ display: DisplayItem) async {
        await runBusy(status: "Turning off \(display.displayTitle)...") {
            let backend = selectedBackend
            try await client.disable(display: display, backend: backend)
            rememberDisabled(display: display, backend: backend)
            selectedDisplayID = display.id
            try await Task.sleep(nanoseconds: 500_000_000)
            let items = try await client.listDisplays()
            displays = items
            status = "Turned off \(display.displayTitle)"
        }
    }

    func restore(_ disabledDisplay: DisabledDisplayRecord) async {
        await restore(id: disabledDisplay.id, backend: disabledDisplay.backend)
    }

    func restore(id: UInt32, backend: DisplayBackend? = nil) async {
        await runBusy(status: "Restoring Display \(id)...") {
            try await client.restore(displayID: id, backend: backend ?? selectedBackend)
            forgetDisabled(id: id)
            try await Task.sleep(nanoseconds: 800_000_000)
            displays = try await client.listDisplays()
            selectedDisplayID = id
            status = "Restored Display \(id)"
        }
    }

    func restoreAllDisabled() async {
        let records = disabledDisplayRecords
        for record in records {
            await restore(record)
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

    private func rememberDisabled(display: DisplayItem, backend: DisplayBackend) {
        disabledDisplayRecords.removeAll { $0.id == display.id }
        disabledDisplayRecords.insert(
            DisabledDisplayRecord(id: display.id, name: display.displayTitle, backend: backend, disabledAt: Date()),
            at: 0
        )
        saveDisabledRecords()
    }

    private func forgetDisabled(id: UInt32) {
        disabledDisplayRecords.removeAll { $0.id == id }
        saveDisabledRecords()
    }

    private func saveDisabledRecords() {
        if let data = try? JSONEncoder().encode(disabledDisplayRecords) {
            UserDefaults.standard.set(data, forKey: disabledRecordsKey)
        }
    }

    private static func loadDisabledRecords(recordsKey: String, legacyIDsKey: String) -> [DisabledDisplayRecord] {
        if let data = UserDefaults.standard.data(forKey: recordsKey),
           let records = try? JSONDecoder().decode([DisabledDisplayRecord].self, from: data) {
            return records
        }

        let raw = UserDefaults.standard.string(forKey: legacyIDsKey) ?? ""
        return raw.split(separator: ",").compactMap { value in
            guard let id = UInt32(value) else { return nil }
            return DisabledDisplayRecord(id: id, name: "Display \(id)", backend: .coregraphics, disabledAt: .distantPast)
        }
    }
}
