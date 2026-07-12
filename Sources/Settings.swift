import AppKit
import SwiftUI
import ServiceManagement
import UserNotifications

/// Grouped Settings form, styled to match Claude Dash's Preferences window.
struct SettingsView: View {
    var onIntervalChange: () -> Void
    var onCheckUpdates: () -> Void
    var onOpenPack: () -> Void

    @State private var intervalMinutes = Prefs.intervalMinutes
    @State private var targetReps = Prefs.targetReps
    @State private var sensitivity = Prefs.sensitivity
    @State private var soundEnabled = Prefs.soundEnabled
    @State private var remindersEnabled = Prefs.remindersEnabled
    @State private var launchAtLogin = (SMAppService.mainApp.status == .enabled)
    @State private var packNotificationShowsNames = Prefs.packNotificationShowsNames
    @ObservedObject private var packStore = PackStore.shared

    var body: some View {
        Form {
            Section {
                Picker("Remind me every", selection: $intervalMinutes) {
                    Text("30 minutes").tag(30)
                    Text("45 minutes").tag(45)
                    Text("1 hour").tag(60)
                    Text("90 minutes").tag(90)
                    Text("2 hours").tag(120)
                }
                Picker("Squats per set", selection: $targetReps) {
                    ForEach([10, 15, 20, 25, 30, 40, 50], id: \.self) { Text("\($0) squats").tag($0) }
                }
                Picker("Sensitivity", selection: $sensitivity) {
                    Text("Easy — a shallow dip counts").tag(0)
                    Text("Normal").tag(1)
                    Text("Strict — needs a deep squat").tag(2)
                }
            }
            Section {
                Toggle("Enable movement reminders", isOn: $remindersEnabled)
                Toggle("Play a sound on each rep", isOn: $soundEnabled)
                Toggle("Launch at login", isOn: $launchAtLogin)
            }
            Section {
                LabeledContent("Status") {
                    Text(packStore.snapshot?.pack.name ?? "Not in a Pack")
                        .foregroundStyle(packStore.isJoined ? .primary : .secondary)
                }
                Button(packStore.isJoined ? "Open Pack…" : "Set Up a Pack…", action: onOpenPack)
                Toggle(
                    "Show member names in notifications",
                    isOn: $packNotificationShowsNames
                )
            } header: {
                Text("Pack")
            } footer: {
                Text("Packs use private, expiring invites and verified membership. They share your chosen name, finished-set totals, and streak. Camera video never leaves this Mac.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Section {
                Button("Check for Updates…", action: onCheckUpdates)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: intervalMinutes) { v in Prefs.intervalMinutes = v; onIntervalChange() }
        .onChange(of: targetReps) { v in Prefs.targetReps = v }
        .onChange(of: sensitivity) { v in Prefs.sensitivity = v }
        .onChange(of: soundEnabled) { v in Prefs.soundEnabled = v }
        .onChange(of: remindersEnabled) { v in
            Prefs.remindersEnabled = v
            if v {
                UNUserNotificationCenter.current().requestAuthorization(
                    options: [.alert, .sound]
                ) { _, _ in }
            }
            onIntervalChange()
        }
        .onChange(of: launchAtLogin) { v in
            do {
                if v { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch { /* non-fatal */ }
        }
        .onChange(of: packNotificationShowsNames) { v in
            Prefs.packNotificationShowsNames = v
        }
    }
}
