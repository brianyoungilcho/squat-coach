import SwiftUI
import ServiceManagement

/// Grouped Settings form, styled to match Claude Dash's Preferences window.
struct SettingsView: View {
    var onIntervalChange: () -> Void
    var onCheckUpdates: () -> Void

    @State private var intervalMinutes = Prefs.intervalMinutes
    @State private var targetReps = Prefs.targetReps
    @State private var sensitivity = Prefs.sensitivity
    @State private var soundEnabled = Prefs.soundEnabled
    @State private var launchAtLogin = (SMAppService.mainApp.status == .enabled)

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
                Toggle("Play a sound on each rep", isOn: $soundEnabled)
                Toggle("Launch at login", isOn: $launchAtLogin)
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
        .onChange(of: launchAtLogin) { v in
            do {
                if v { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch { /* non-fatal */ }
        }
    }
}
