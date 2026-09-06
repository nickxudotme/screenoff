import SwiftUI

@main
struct ScreenOffApp: App {
    @StateObject private var store = DisplayStore()

    var body: some Scene {
        WindowGroup("ScreenOff") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 620, minHeight: 420)
                .task {
                    await store.refresh()
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Displays") {
                Button("Refresh") {
                    Task { await store.refresh() }
                }
                .keyboardShortcut("r", modifiers: [.command])

                Button("Reconnect All External Displays") {
                    Task { await store.reconnectAll() }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(store.disconnectedDisplayIDs.isEmpty || store.isBusy)
            }
        }
    }
}
