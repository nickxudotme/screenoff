import SwiftUI
import ScreenOffKit

struct ContentView: View {
    @EnvironmentObject private var store: DisplayStore
    @State private var pendingDisable: DisplayItem?
    @State private var manualRestoreID = ""

    var body: some View {
        NavigationSplitView {
            List(selection: $store.selectedDisplayID) {
                Section("Active") {
                    ForEach(store.displays) { display in
                        DisplayRow(display: display)
                            .tag(display.id)
                    }
                }

                if !store.disabledDisplayRecords.isEmpty {
                    Section("Off") {
                        ForEach(store.disabledDisplayRecords) { display in
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
            DetailView(pendingDisable: $pendingDisable, manualRestoreID: $manualRestoreID)
        }
        .alert("Turn off this display?", isPresented: Binding(
            get: { pendingDisable != nil },
            set: { if !$0 { pendingDisable = nil } }
        ), presenting: pendingDisable) { display in
            Button("Turn Off", role: .destructive) {
                Task { await store.disable(display) }
                pendingDisable = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDisable = nil
            }
        } message: { display in
            Text("\(display.displayTitle) will disappear from the macOS desktop layout. Restore it later with its display ID: \(display.id).")
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
                Text("ID \(display.id) \(display.geometry)")
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
    let display: DisabledDisplayRecord

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(display.title)
                Text("ID \(display.id)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(display.backend.label)
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
    @Binding var manualRestoreID: String

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            Divider()

            if let disabled = store.selectedDisabledDisplay {
                DisabledDisplayDetail(display: disabled)
            } else if let display = store.selectedDisplay {
                ActiveDisplayDetail(display: display, pendingDisable: $pendingDisable)
            } else {
                EmptySelectionView()
            }

            BackendPicker()
            ManualRestoreView(manualRestoreID: $manualRestoreID)

            Spacer()

            if let error = store.errorMessage {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            HStack {
                if store.isBusy {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(store.status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(24)
        .navigationTitle("Control")
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "rectangle.2.swap")
                .font(.system(size: 28))
                .foregroundStyle(.blue)

            VStack(alignment: .leading, spacing: 3) {
                Text("ScreenOff")
                    .font(.title2.weight(.semibold))
                Text("Turn displays off and restore them from the macOS desktop layout.")
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }
}

private struct BackendPicker: View {
    @EnvironmentObject private var store: DisplayStore

    var body: some View {
        Picker("Backend", selection: $store.selectedBackend) {
            ForEach(DisplayBackend.allCases) { backend in
                Text(backend.label).tag(backend)
            }
        }
        .pickerStyle(.segmented)
    }
}

private struct ManualRestoreView: View {
    @EnvironmentObject private var store: DisplayStore
    @Binding var manualRestoreID: String

    private var parsedID: UInt32? {
        UInt32(manualRestoreID.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Restore by ID")
                .font(.headline)

            HStack {
                TextField("Display ID", text: $manualRestoreID)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)

                Button {
                    guard let id = parsedID else { return }
                    Task { await store.restore(id: id) }
                } label: {
                    Label("Restore", systemImage: "rectangle.badge.plus")
                }
                .disabled(parsedID == nil || store.isBusy)
            }

            Text("Use this when an off display is not listed. Enter the display ID reported by the CLI.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 4)
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
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: display.isBuiltIn ? "laptopcomputer" : "display")
                    .font(.system(size: 44))
                    .foregroundStyle(display.isMain ? .blue : .primary)

                VStack(alignment: .leading, spacing: 4) {
                    Text(display.displayTitle)
                        .font(.title3.weight(.semibold))
                    Text("Display ID \(display.id)")
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
                    Label("Turn Off Display", systemImage: "rectangle.badge.minus")
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
    let display: DisabledDisplayRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "display.trianglebadge.exclamationmark")
                    .font(.system(size: 44))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text(display.title)
                        .font(.title3.weight(.semibold))
                    Text("Turned off from the desktop layout")
                        .foregroundStyle(.secondary)
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    Text("Display ID").foregroundStyle(.secondary)
                    Text("\(display.id)")
                }
                GridRow {
                    Text("Backend").foregroundStyle(.secondary)
                    Text(display.backend.label)
                }
                GridRow {
                    Text("Turned Off").foregroundStyle(.secondary)
                    Text(display.disabledAt == .distantPast ? "Unknown" : display.disabledAt.formatted(date: .abbreviated, time: .shortened))
                }
            }

            Button {
                Task { await store.restore(display) }
            } label: {
                Label("Restore Display", systemImage: "rectangle.badge.plus")
            }
            .disabled(store.isBusy)
        }
    }
}
