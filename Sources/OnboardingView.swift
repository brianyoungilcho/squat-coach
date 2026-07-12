import SwiftUI

struct OnboardingView: View {
    let onFinish: (_ enableNotifications: Bool) -> Void

    @State private var targetReps = Prefs.targetReps
    @State private var intervalMinutes = Prefs.intervalMinutes
    @State private var enableNotifications = true

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "figure.strengthtraining.functional")
                    .font(.system(size: 32))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text("Welcome to Squat Coach")
                    .font(.title2.bold())
                Text("Short movement breaks, counted privately on your Mac.")
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 14) {
                onboardingRow(
                    symbol: "video",
                    title: "Camera stays local",
                    detail: "Apple Vision counts your reps. Video is never recorded or uploaded."
                )
                onboardingRow(
                    symbol: "bell",
                    title: "You stay in control",
                    detail: "Reminders offer Start, Snooze, or Skip. The camera opens only after Start."
                )
                onboardingRow(
                    symbol: "person.3",
                    title: "Packs are optional",
                    detail: "Join friends later with a private invite. Only workout totals you finish are shared."
                )
            }

            Form {
                Picker("Squats per set", selection: $targetReps) {
                    ForEach([10, 15, 20, 25, 30, 40, 50], id: \.self) {
                        Text("\($0) squats").tag($0)
                    }
                }
                Picker("Remind me every", selection: $intervalMinutes) {
                    Text("30 minutes").tag(30)
                    Text("45 minutes").tag(45)
                    Text("1 hour").tag(60)
                    Text("90 minutes").tag(90)
                    Text("2 hours").tag(120)
                }
                Toggle("Enable movement reminders", isOn: $enableNotifications)
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Get started") {
                    Prefs.targetReps = targetReps
                    Prefs.intervalMinutes = intervalMinutes
                    Prefs.remindersEnabled = enableNotifications
                    Prefs.onboardingCompleted = true
                    onFinish(enableNotifications)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 500)
    }

    private func onboardingRow(symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .frame(width: 22)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
