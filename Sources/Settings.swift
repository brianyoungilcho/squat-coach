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
    @State private var packShareEnabled = Prefs.packShareEnabled
    @State private var packCode = Prefs.packCode
    @State private var packWebhookURL = Prefs.packWebhookURL
    @State private var packDisplayName = Prefs.packDisplayName

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
                Toggle("Share finished sets with your pack", isOn: $packShareEnabled)
                TextField("Pack code", text: $packCode,
                          prompt: Text("e.g. SQT-BROS — same code as your friends"))
                    .autocorrectionDisabled()
                TextField("Display name", text: $packDisplayName,
                          prompt: Text(NSFullUserName()))
                TextField("Slack webhook (optional)", text: $packWebhookURL,
                          prompt: Text("https://hooks.slack.com/services/…"))
                    .autocorrectionDisabled()
                Button("Send a test post") { PackShare.postTest() }
                    .disabled(!packShareEnabled ||
                              !packWebhookURL.trimmingCharacters(in: .whitespacesAndNewlines)
                                  .hasPrefix("https://"))
            } header: {
                Text("Pack")
            } footer: {
                Text("Everyone with the same pack code (4+ characters, case doesn't matter) sees each other in the menu and gets a nudge when someone finishes a set. Shares only a random install id, your name, set counts, and streak — video never leaves your Mac. The Slack webhook additionally posts each set to a channel; see the README for both setups.")
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
        .onChange(of: launchAtLogin) { v in
            do {
                if v { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch { /* non-fatal */ }
        }
        .onChange(of: packShareEnabled) { v in
            Prefs.packShareEnabled = v
            // Arm the digest for tomorrow — enabling at 8 PM shouldn't post a
            // "yesterday" recap that same evening.
            if v { Prefs.lastDigestDay = Prefs.dayString(Date()) }
        }
        .onChange(of: packCode) { v in
            Prefs.packCode = PackSyncLogic.normalizedPackCode(v)
            PackSync.shared.packChanged()
        }
        .onChange(of: packWebhookURL) { v in
            Prefs.packWebhookURL = v.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        .onChange(of: packDisplayName) { v in Prefs.packDisplayName = v }
    }
}
