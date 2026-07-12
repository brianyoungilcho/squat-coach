import SwiftUI

struct PackView: View {
    @ObservedObject var store: PackStore
    let initialInvite: String?

    @State private var packName = ""
    @State private var inviteValue: String
    @State private var displayName = Prefs.socialDisplayName
    @State private var showingCreate = false
    @State private var confirmation: PackConfirmation?

    init(store: PackStore, initialInvite: String? = nil) {
        self.store = store
        self.initialInvite = initialInvite
        _inviteValue = State(initialValue: initialInvite ?? "")
    }

    var body: some View {
        Group {
            switch store.state {
            case .disconnected, .ready:
                setupView
            case .authenticating:
                progressView("Creating a private identity…")
            case .creating:
                progressView("Creating your Pack…")
            case .joining:
                progressView("Joining Pack…")
            case .joined(let snapshot):
                joinedView(snapshot: snapshot, message: nil)
            case .refreshing(let snapshot):
                joinedView(snapshot: snapshot, message: "Refreshing…")
            case .offline(let snapshot, let message):
                if let snapshot {
                    joinedView(snapshot: snapshot, message: message)
                } else {
                    setupView
                }
            case .failed(let message):
                setupView
                    .safeAreaInset(edge: .bottom) {
                        statusBanner(message: message, symbol: "exclamationmark.triangle")
                    }
            }
        }
        .frame(minWidth: 620, idealWidth: 700, minHeight: 520, idealHeight: 640)
        .task { store.bootstrap() }
        .confirmationDialog(
            confirmation?.title ?? "",
            isPresented: Binding(
                get: { confirmation != nil },
                set: { if !$0 { confirmation = nil } }
            ),
            titleVisibility: .visible
        ) {
            if confirmation == .delete {
                Button("Delete Pack for everyone", role: .destructive) {
                    Task { await store.deletePack() }
                }
            } else {
                Button("Leave Pack", role: .destructive) {
                    Task { await store.leavePack() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmation?.message ?? "")
        }
    }

    private var setupView: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Squat with your Pack")
                    .font(.title2.bold())
                Text("See who moved today, celebrate finished sets, and keep momentum together.")
                    .foregroundStyle(.secondary)
            }

            if Prefs.hasLegacyPackConfiguration && !Prefs.acknowledgedSocialPackReset {
                statusBanner(
                    message: "Packs now verify membership. Your old code can’t be migrated safely; create a new Pack or ask for a fresh invite. Local workout history is unchanged.",
                    symbol: "arrow.triangle.2.circlepath"
                )
                Button("Acknowledge Pack upgrade") {
                    Prefs.clearLegacyPackConfiguration()
                    Prefs.acknowledgedSocialPackReset = true
                }
            }

            TextField("Name friends will see", text: $displayName)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Pack display name")

            HStack(alignment: .top, spacing: 18) {
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Start a Pack").font(.headline)
                        Text("Create a named group, then share a private invite.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        TextField("Pack name", text: $packName)
                            .textFieldStyle(.roundedBorder)
                        Button("Create Pack") {
                            Task { await store.createPack(name: packName, displayName: displayName) }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(clean(displayName).isEmpty || clean(packName).isEmpty)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Join a Pack").font(.headline)
                        Text("Open an invite link or paste it here.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        TextField("squatcoach://join/…", text: $inviteValue)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Pack invite")
                            .onSubmit { join() }
                        Button("Join Pack", action: join)
                            .buttonStyle(.borderedProminent)
                            .disabled(
                                clean(displayName).isEmpty ||
                                    PackInviteParser.token(from: inviteValue) == nil
                            )
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }
            }

            Spacer()
            Label(
                "Camera video stays on this Mac. Packs share your chosen name, finished-set totals, and streak.",
                systemImage: "lock.shield"
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .padding(24)
    }

    private func joinedView(snapshot: PackSnapshot, message: String?) -> some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(snapshot.pack.name)
                        .font(.title2.bold())
                    Text("\(snapshot.members.count) \(snapshot.members.count == 1 ? "member" : "members")")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if store.pendingDeliveryCount > 0 {
                    Label(
                        "\(store.pendingDeliveryCount) pending",
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Button {
                    store.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            .padding(20)

            if let message {
                statusBanner(message: message, symbol: "wifi.exclamationmark")
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
            }

            HSplitView {
                membersView(snapshot)
                    .frame(minWidth: 190, idealWidth: 220)
                activityView(snapshot)
                    .frame(minWidth: 380)
            }

            Divider()
            joinedFooter(snapshot)
                .padding(14)
        }
    }

    private func membersView(_ snapshot: PackSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Members")
                .font(.headline)
            List(snapshot.members) { member in
                HStack {
                    Image(systemName: member.role == .owner ? "crown" : "person")
                        .accessibilityHidden(true)
                    VStack(alignment: .leading) {
                        Text(member.displayName)
                        if member.userId == snapshot.currentUserId {
                            Text("You").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
        .padding()
    }

    private func activityView(_ snapshot: PackSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recent activity")
                .font(.headline)
            if snapshot.activities.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "figure.strengthtraining.functional")
                        .font(.title)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text("No finished sets yet").font(.headline)
                    Text("The first completed set will appear here.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(snapshot.activities) { activity in
                    activityRow(activity, snapshot: snapshot)
                }
                .listStyle(.inset)
            }
        }
        .padding()
    }

    private func activityRow(_ activity: PackActivity, snapshot: PackSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(activity.member.displayName).font(.headline)
                Spacer()
                Text(activity.event.occurredAt, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(
                "\(activity.event.reps) squats · \(activity.event.sets) " +
                    "\(activity.event.sets == 1 ? "set" : "sets") today · " +
                    "\(activity.event.streak)-day streak"
            )
            .font(.callout)

            HStack(spacing: 8) {
                ForEach(ReactionKind.allCases, id: \.self) { kind in
                    let count = activity.reactions.filter { $0.kind == kind }.count
                    let selected = activity.reactions.contains {
                        $0.kind == kind && $0.userId == snapshot.currentUserId
                    }
                    Button {
                        Task { await store.toggleReaction(kind: kind, activity: activity) }
                    } label: {
                        Label(
                            count > 0 ? "\(kind.label) \(count)" : kind.label,
                            systemImage: kind.symbolName
                        )
                    }
                    .buttonStyle(.bordered)
                    .tint(selected ? .accentColor : nil)
                    .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 5)
    }

    private func joinedFooter(_ snapshot: PackSnapshot) -> some View {
        let currentMember = snapshot.members.first { $0.userId == snapshot.currentUserId }
        let isOwner = currentMember?.role == .owner
        return HStack {
            if isOwner {
                if let invite = store.currentInvite, let url = invite.url {
                    ShareLink(item: url) {
                        Label("Share invite", systemImage: "square.and.arrow.up")
                    }
                } else {
                    Button {
                        Task { await store.rotateInvite() }
                    } label: {
                        Label("Create invite", systemImage: "person.badge.plus")
                    }
                }
                Button("Rotate invite") {
                    Task { await store.rotateInvite() }
                }
            }
            Spacer()
            Button(isOwner ? "Delete Pack…" : "Leave Pack…", role: .destructive) {
                confirmation = isOwner ? .delete : .leave
            }
        }
    }

    private func progressView(_ label: String) -> some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(label).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func statusBanner(message: String, symbol: String) -> some View {
        Label {
            Text(message).font(.callout)
        } icon: {
            Image(systemName: symbol)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private func join() {
        Task { await store.joinPack(inviteValue: inviteValue, displayName: displayName) }
    }

    private func clean(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private enum PackConfirmation {
    case leave
    case delete

    var title: String {
        switch self {
        case .leave:
            return "Leave this Pack?"
        case .delete:
            return "Delete this Pack?"
        }
    }

    var message: String {
        switch self {
        case .leave:
            return "Your local workout history stays on this Mac. You’ll need a new invite to return."
        case .delete:
            return "This removes the Pack, memberships, activity, reactions, and active invites for everyone."
        }
    }
}
