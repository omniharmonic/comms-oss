import CommsClient
import CommsCore
import SwiftUI

/// Settings › Notifications (Sprint Task 1, D18 + D10). Laid out like the system's own
/// notification settings: an Allow switch, what to be told about, networks, lock-screen
/// previews, then Messages' "Send Read Receipts". A grouped form on both platforms (macOS
/// Settings window, iOS sheet).
public struct NotificationSettingsView: View {
    @Bindable var store: NotificationSettingsStore
    /// Whether this device has push permission (nil = unknown / not asked).
    let devicePermission: Bool?

    public init(store: NotificationSettingsStore, devicePermission: Bool? = nil) {
        self.store = store
        self.devicePermission = devicePermission
    }

    public var body: some View {
        Form {
            Section {
                Toggle("Allow Notifications", isOn: binding(\.enabled))
                    .accessibilityIdentifier("notify-allow")
            } footer: {
                if let note = availabilityNote { Text(note) }
            }

            Section {
                ForEach(Self.statusRows, id: \.key) { row in
                    Toggle(row.title, isOn: statusBinding(row.path))
                        .accessibilityIdentifier("notify-status-\(row.key)")
                }
            } header: {
                Text("Notify Me About")
            } footer: {
                Text("Comms sorts each conversation by its Prism tag. Unknown senders and spam never notify.")
            }
            .disabled(!store.settings.enabled)

            if !store.folders.isEmpty {
                Section {
                    ForEach(store.folders) { folder in
                        Picker(selection: Binding(get: { store.folderRule(folder.id) }, set: { store.setFolderRule(folder.id, $0) })) {
                            ForEach(CommsFolderNotify.allCases, id: \.self) { rule in
                                Text(rule.title).tag(rule)
                            }
                        } label: {
                            Label(folder.name, systemImage: "folder")
                        }
                        .pickerStyle(.menu)
                        .accessibilityIdentifier("notify-folder-\(folder.name)")
                    }
                } header: {
                    Text("Folders")
                } footer: {
                    Text("All Messages notifies for every new message in the folder, whatever its tag or network. None silences the folder. Default follows the settings above. A muted conversation stays silent, and spam never notifies.")
                }
                .disabled(!store.settings.enabled)
            }

            Section {
                Toggle("People I Know, Right Away", isOn: binding(\.knownPeopleImmediately))
                    .accessibilityIdentifier("notify-known-people")
            } footer: {
                Text("A direct message from someone in your people notes notifies as it arrives, before Comms has sorted it.")
            }
            .disabled(!store.settings.enabled)

            Section("Networks") {
                ForEach(NotificationSettingsStore.networks, id: \.wire) { network in
                    Toggle(isOn: Binding(get: { store.notifies(network) }, set: { store.setNotifies(network, $0) })) {
                        Label { Text(network.title) } icon: { NetworkGlyph(network: network) }
                    }
                    .accessibilityIdentifier("notify-network-\(network.wire)")
                }
            }
            .disabled(!store.settings.enabled)

            Section {
                Toggle("Show Previews", isOn: Binding(get: { !store.settings.hidePreviews }, set: { v in store.update { $0.hidePreviews = !v } }))
                    .accessibilityIdentifier("notify-show-previews")
            } header: {
                Text("Lock Screen")
            } footer: {
                Text(store.settings.hidePreviews
                     ? "Notifications say only “New message” — no name and no text."
                     : "Notifications show who wrote and the start of the message.")
            }
            .disabled(!store.settings.enabled)

            Section {
                Toggle("Send Read Receipts", isOn: binding(\.readReceipts))
                    .accessibilityIdentifier("notify-read-receipts")
            } footer: {
                Text(receiptsFooter)
            }

            if let devices = store.devices {
                Section {
                    ForEach(Array(devices.enumerated()), id: \.offset) { _, d in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(NotificationSettingsStore.deviceName(d))
                            Text(NotificationSettingsStore.deliveryText(d))
                                .font(.footnote)
                                .foregroundStyle(d.lastDelivery.map { $0.outcome == "sent" } ?? true ? Color.secondary : Color.red)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    Button {
                        Task { await store.sendTest() }
                    } label: {
                        HStack {
                            Text("Send Test Notification")
                            if store.isTesting { Spacer(); ProgressView().controlSize(.small) }
                        }
                    }
                    .disabled(store.isTesting || store.available?.push == false)
                    .accessibilityIdentifier("notify-send-test")
                } header: {
                    Text("Devices")
                } footer: {
                    Text(store.testMessage ?? "The devices signed in to Comms that receive notifications.")
                }
            }

            if let error = store.error {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Notifications")
        // Fresh every time the screen appears (a Settings window can stay open for days).
        .task { await store.load() }
    }

    /// Every Prism triage tag, in the list's order, with the name the app shows for it.
    static var statusRows: [(key: String, title: String, path: WritableKeyPath<CommsNotifySettings.Statuses, Bool>)] { [
        ("urgent", "Urgent", \.urgent),
        ("action-required", "Action Required", \.actionRequired),
        ("informational", "Informational", \.informational),
        ("low", "Low Priority", \.low),
        ("social", "Social", \.social),
        ("triaged", "Reviewed", \.triaged),
        ("handled", "Handled", \.handled),
        ("unclassified", "Not Yet Sorted", \.unclassified),
    ] }

    private func binding<T>(_ path: WritableKeyPath<CommsNotifySettings, T>) -> Binding<T> {
        Binding(get: { store.settings[keyPath: path] }, set: { v in store.update { $0[keyPath: path] = v } })
    }

    private func statusBinding(_ path: WritableKeyPath<CommsNotifySettings.Statuses, Bool>) -> Binding<Bool> {
        Binding(get: { store.settings.statuses[keyPath: path] }, set: { v in store.update { $0.statuses[keyPath: path] = v } })
    }

    private var availabilityNote: String? {
        if devicePermission == false { return "Notifications are turned off for Comms in System Settings." }
        if store.available?.push == false { return "Your Prism server isn't sending notifications yet." }
        return nil
    }

    private var receiptsFooter: String {
        var text = "When this is on, people are notified when you have read their messages, where the network supports it. When it is off, only Mark as Read tells them."
        if store.available?.readReceipts == false { text += " Read receipts are switched off on your Prism server, so none are sent." }
        return text
    }
}

/// The network's badge glyph at list size (reuses the avatar badge artwork).
private struct NetworkGlyph: View {
    let network: CommsNetwork
    var body: some View {
        NetworkBadge(network: network, size: 20, ring: .clear)
            .accessibilityHidden(true)
    }
}
