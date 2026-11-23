import CommsClient
import Foundation
import Observation

/// Settings › Notifications (Sprint Task 1, D18 + D10): the owner's server-side choices. Changes
/// apply at once on screen and are saved in order; a save that fails puts the last saved
/// settings back and says so.
@MainActor @Observable
public final class NotificationSettingsStore {
    public private(set) var settings: CommsNotifySettings = .defaults
    /// What the server can do (nil until loaded).
    public private(set) var available: CommsNotifyAvailability?
    public private(set) var isLoading = false
    public private(set) var error: String?
    /// The owner's folders (Settings › Notifications › Folders); empty when the server has none.
    public private(set) var folders: [CommsChatFolder] = []
    /// The owner's Comms devices and what Apple last answered for each (nil from an older server).
    public private(set) var devices: [CommsPushDevice]?
    /// "Send Test Notification" is on its way.
    public private(set) var isTesting = false
    /// The test's outcome in words (nil before one ran).
    public private(set) var testMessage: String?
    /// The networks the Networks section lists, in Comms' order.
    public static let networks: [CommsNetwork] = [.imessage, .sms, .whatsapp, .telegram, .signal, .messenger, .instagram, .slack, .discord, .linkedin, .x, .email, .matrix]

    @ObservationIgnored private let backend: any ChatBackend
    @ObservationIgnored private var saved: CommsNotifySettings = .defaults
    /// The save in flight (tests await it).
    @ObservationIgnored public private(set) var saveWork: Task<Void, Never>?

    public init(backend: any ChatBackend) {
        self.backend = backend
    }

    /// For snapshots and previews: show these settings without asking the server.
    public init(backend: any ChatBackend, settings: CommsNotifySettings, available: CommsNotifyAvailability?, folders: [CommsChatFolder] = []) {
        self.backend = backend
        self.settings = settings
        self.saved = settings
        self.available = available
        self.folders = folders
    }

    public func load() async {
        await saveWork?.value // never replace an edit that is still on its way
        isLoading = true
        defer { isLoading = false }
        do {
            let r = try await backend.notificationSettings()
            settings = r.settings
            saved = r.settings
            available = r.available
            devices = r.devices
            error = nil
        } catch {
            self.error = "Couldn't load notification settings."
        }
        if backend.foldersSupported, let f = try? await backend.folders() {
            folders = f.sorted { $0.position < $1.position }
        } else if !backend.foldersSupported {
            folders = []
        }
    }

    /// Send a test notification to every Comms device and show what each answered.
    public func sendTest() async {
        guard !isTesting else { return }
        isTesting = true
        defer { isTesting = false }
        do {
            let r = try await backend.sendTestNotification()
            devices = r.devices
            let failed = r.devices.filter { $0.lastDelivery?.outcome != "sent" }
            testMessage = r.devices.isEmpty ? "No device is registered for notifications yet."
                : failed.isEmpty ? "Sent. Each device should show “Notifications are working”."
                : "Apple didn't deliver to \(failed.map(Self.deviceName).joined(separator: ", "))."
        } catch {
            testMessage = "Couldn't send a test notification."
        }
    }

    /// "This iPhone", "Mac", … for a device row.
    public static func deviceName(_ d: CommsPushDevice) -> String {
        let kind = d.platform == "ios" ? "iPhone or iPad" : d.platform == "macos" ? "Mac" : "Device"
        return d.thisDevice ? "This \(kind == "iPhone or iPad" ? "iPhone" : kind)" : kind
    }

    /// One line under a device: its push environment and what Apple last answered.
    public static func deliveryText(_ d: CommsPushDevice) -> String {
        let env = d.environment == "sandbox" ? "Development build" : "App Store / Developer ID build"
        guard let last = d.lastDelivery else { return "\(env) · nothing sent yet" }
        if last.outcome == "sent" { return "\(env) · last notification delivered to Apple" }
        if last.outcome == "pruned" { return "\(env) · Apple says this registration is no longer valid (\(last.reason)) — open Comms on it to register again" }
        let why = last.status.map { "\($0)\(last.reason.isEmpty ? "" : " \(last.reason)")" } ?? (last.reason.isEmpty ? "no answer" : last.reason)
        return "\(env) · Apple refused the last notification (\(why))"
    }

    /// Change and save. `change` edits a copy of the current settings.
    public func update(_ change: (inout CommsNotifySettings) -> Void) {
        var next = settings
        change(&next)
        guard next != settings else { return }
        // Only what this edit changed goes to the server (review I4): a screen loaded earlier never
        // resends — and so never undoes — what another device changed meanwhile (Hide Previews!).
        let patch = CommsNotifySettingsPatch.diff(from: settings, to: next)
        settings = next
        let prev = saveWork
        let backend = self.backend
        saveWork = Task { [weak self] in
            await prev?.value
            do {
                let r = try await backend.updateNotificationSettings(patch)
                guard let self else { return }
                self.saved = r.settings
                self.available = r.available
                self.error = nil
                // The server's merged settings, with any later edits still on their way kept on top.
                if self.settings == next { self.settings = r.settings }
            } catch {
                guard let self else { return }
                if self.settings == next { self.settings = self.saved }
                self.error = "Couldn't save. Check your connection and try again."
            }
        }
    }

    // MARK: Bindable helpers

    public func notifies(_ network: CommsNetwork) -> Bool { settings.notifies(network: network) }
    public func setNotifies(_ network: CommsNetwork, _ on: Bool) {
        // Explicit true (not a removed key): the server merges network maps key by key.
        update { $0.networks[network.wire] = on }
    }

    public func folderRule(_ id: String) -> CommsFolderNotify { settings.notify(folder: id) }
    public func setFolderRule(_ id: String, _ rule: CommsFolderNotify) {
        update { $0.folders[id] = rule == .default ? nil : rule }
    }
}
