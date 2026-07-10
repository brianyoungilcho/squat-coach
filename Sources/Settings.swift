import AppKit
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
    @State private var joinCode = ""
    @State private var inviteCopied = false
    @State private var packWebhookURL = Prefs.packWebhookURL
    @State private var packDisplayName = Prefs.packDisplayName

    private var normalizedJoinCode: String { PackSyncLogic.normalizedPackCode(joinCode) }

    /// The one path every pack membership change goes through.
    private func setPack(_ code: String) {
        packCode = code
        Prefs.packCode = code
        joinCode = ""
        inviteCopied = false
        PackSync.shared.packChanged()
    }

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
                if packCode.isEmpty {
                    LabeledContent("Start a pack") {
                        Button("Create a pack") {
                            setPack(PackSyncLogic.generatePackCode())
                            if !packShareEnabled { packShareEnabled = true }
                        }
                    }
                    LabeledContent("Join a pack") {
                        HStack {
                            TextField("", text: $joinCode,
                                      prompt: Text("paste an invite code"))
                                .autocorrectionDisabled()
                                .onSubmit { joinIfValid() }
                            Button("Join") { joinIfValid() }
                                .disabled(!PackSyncLogic.isValidPackCode(normalizedJoinCode))
                        }
                    }
                } else {
                    LabeledContent("Pack code") {
                        Text(PackSyncLogic.displayPackCode(packCode))
                            .textSelection(.enabled)
                            .font(.body.monospaced())
                    }
                    LabeledContent("") {
                        HStack {
                            Button(inviteCopied ? "Copied ✓" : "Copy invite") {
                                let pb = NSPasteboard.general
                                pb.clearContents()
                                pb.setString(PackSyncLogic.inviteMessage(code: packCode),
                                             forType: .string)
                                inviteCopied = true
                            }
                            Button("Leave pack") { setPack("") }
                        }
                    }
                }
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
                Text("Create a pack, hit Copy invite, and send it to your friends — everyone with the code sees each other in the menu and gets a nudge when someone finishes a set. Codes are auto-generated and unguessable; treat yours like a house key. Shares only a random install id, your name, set counts, and streak — video never leaves your Mac. The Slack webhook additionally posts each set to a channel; see the README.")
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
        .onChange(of: packWebhookURL) { v in
            Prefs.packWebhookURL = v.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        .onChange(of: packDisplayName) { v in Prefs.packDisplayName = v }
    }

    private func joinIfValid() {
        let code = normalizedJoinCode
        guard PackSyncLogic.isValidPackCode(code) else { return }
        setPack(code)
        if !packShareEnabled { packShareEnabled = true }
    }
}
