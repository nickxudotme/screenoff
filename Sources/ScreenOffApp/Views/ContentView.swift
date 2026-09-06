import SwiftUI
import ScreenOffKit

struct ContentView: View {
    @EnvironmentObject private var store: DisplayStore
    @State private var pendingDisable: DisplayItem?

    var body: some View {
        NavigationSplitView {
            List(selection: $store.selectedDisplayID) {
                Section("Active") {
                    ForEach(store.displays) { display in
                        DisplayRow(display: display)
                            .tag(display.id)
                    }
                }

                if !store.disconnectedDisplays.isEmpty {
                    Section("Disconnected") {
                        ForEach(store.disconnectedDisplays) { display in
                            DisabledDisplayRow(display: display)
                                .tag(display.id)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("Displays")
            .toolbar {
                ToolbarItem {
                    Button {
                        Task { await store.refresh() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(store.isBusy)
                }
            }
        } detail: {
            DetailView(pendingDisable: $pendingDisable)
        }
        .alert("Disconnect this display?", isPresented: Binding(
            get: { pendingDisable != nil },
            set: { if !$0 { pendingDisable = nil } }
        ), presenting: pendingDisable) { display in
            Button("Disconnect", role: .destructive) {
                Task { await store.disconnect(display) }
                pendingDisable = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDisable = nil
            }
        } message: { display in
            Text("\(display.displayTitle) will disappear from the macOS desktop layout. It remains available here for one-click reconnection.")
        }
    }
}

private struct DisplayRow: View {
    let display: DisplayItem

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(display.displayTitle)
                    .lineLimit(1)
                Text(display.geometry)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } icon: {
            Image(systemName: display.isBuiltIn ? "laptopcomputer" : "display")
                .foregroundStyle(display.isMain ? .blue : .secondary)
        }
    }
}

private struct DisabledDisplayRow: View {
    let display: DisplayItem

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(display.displayTitle)
                Text("Disconnected")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "display.trianglebadge.exclamationmark")
                .foregroundStyle(.orange)
        }
    }
}

private struct DetailView: View {
    @EnvironmentObject private var store: DisplayStore
    @Binding var pendingDisable: DisplayItem?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let disabled = store.selectedDisconnectedDisplay {
                        DisabledDisplayDetail(display: disabled)
                    } else if let display = store.selectedDisplay {
                        ActiveDisplayDetail(display: display, pendingDisable: $pendingDisable)
                    } else {
                        EmptySelectionView()
                    }

                    Divider()

                    if let error = store.errorMessage {
                        Text(error)
                            .font(.callout)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: 760, alignment: .leading)
                .padding(24)
                .padding(.bottom, 18)
            }

        }
        .navigationTitle("Control")
    }
}

private struct EmptySelectionView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "display")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("No Display Selected")
                .font(.title3.weight(.semibold))
            Text("Choose a display from the sidebar.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ActiveDisplayDetail: View {
    @EnvironmentObject private var store: DisplayStore
    let display: DisplayItem
    @Binding var pendingDisable: DisplayItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: display.isBuiltIn ? "laptopcomputer" : "display")
                    .font(.system(size: 42))
                    .foregroundStyle(display.isMain ? .blue : .primary)
                    .frame(width: 54)

                VStack(alignment: .leading, spacing: 4) {
                    Text(display.displayTitle)
                        .font(.title2.weight(.semibold))
                    Text(display.geometry)
                        .foregroundStyle(.secondary)
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    Text("Geometry").foregroundStyle(.secondary)
                    Text(display.geometry)
                }
                GridRow {
                    Text("State").foregroundStyle(.secondary)
                    Text(display.state)
                }
                GridRow {
                    Text("Flags").foregroundStyle(.secondary)
                    Text(display.flags.isEmpty ? "none" : display.flags.joined(separator: ", "))
                }
            }

            HStack {
                Button(role: .destructive) {
                    pendingDisable = display
                } label: {
                    Label("Disconnect Display", systemImage: "rectangle.badge.minus")
                }
                .disabled(display.isMain || store.isBusy)

                Button {
                    Task { await store.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(store.isBusy)
            }

            if display.isMain {
                Text("The main display is protected in the GUI.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct DisabledDisplayDetail: View {
    @EnvironmentObject private var store: DisplayStore
    let display: DisplayItem

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "display.trianglebadge.exclamationmark")
                    .font(.system(size: 42))
                    .foregroundStyle(.orange)
                    .frame(width: 54)
                VStack(alignment: .leading, spacing: 4) {
                    Text(display.displayTitle)
                        .font(.title2.weight(.semibold))
                    Text("Disconnected from the desktop layout")
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                Task { await store.reconnect(display) }
            } label: {
                Label("Reconnect Display", systemImage: "rectangle.badge.plus")
            }
            .disabled(store.isBusy)
        }
    }
}
