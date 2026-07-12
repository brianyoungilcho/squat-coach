import Combine
import Foundation
import Supabase
import UserNotifications

@MainActor
final class PackStore: ObservableObject {
    static let shared = PackStore()

    @Published private(set) var state: PackLoadState = .disconnected
    @Published private(set) var currentInvite: PackInvite?
    @Published private(set) var pendingDeliveryCount = 0

    private let auth: AuthSession
    private let repository: PackRepository
    private let outbox: SocialOutbox
    private var currentUserId: UUID?
    private var refreshGeneration = 0
    private var refreshTask: Task<Void, Never>?
    private var pollingTask: Task<Void, Never>?
    private var realtimeTask: Task<Void, Never>?
    private var realtimeRefreshTask: Task<Void, Never>?

    init(
        auth: AuthSession = AuthSession(),
        repository: PackRepository = PackRepository(),
        outbox: SocialOutbox = SocialOutbox()
    ) {
        self.auth = auth
        self.repository = repository
        self.outbox = outbox
    }

    var snapshot: PackSnapshot? {
        switch state {
        case .joined(let snapshot), .refreshing(let snapshot):
            return snapshot
        case .offline(let snapshot, _):
            return snapshot
        case .disconnected, .authenticating, .ready, .creating, .joining, .failed:
            return nil
        }
    }

    var isJoined: Bool { snapshot != nil }

    func bootstrap() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            guard let self else { return }
            defer { refreshTask = nil }
            do {
                guard let userId = try await auth.currentUserId() else {
                    state = .ready
                    return
                }
                currentUserId = userId
                let membership: PackMember?
                if let activePackId = Prefs.activeSocialPackId {
                    membership = PackMember(
                        packId: activePackId,
                        userId: userId,
                        displayName: Prefs.socialDisplayName,
                        role: .member,
                        joinedAt: .distantPast
                    )
                } else {
                    membership = try await repository.mostRecentMembership()
                }
                guard let membership else {
                    state = .ready
                    return
                }
                Prefs.activeSocialPackId = membership.packId
                try await load(packId: membership.packId, userId: userId)
                startLiveUpdates(packId: membership.packId)
                await flushOutbox()
            } catch {
                if isMissingPack(error) {
                    clearMembership()
                } else {
                    state = .failed(message: userMessage(for: error))
                }
            }
        }
    }

    func createPack(name: String, displayName: String) async {
        let cleanName = sanitized(name, maxLength: 40)
        let cleanDisplayName = sanitized(displayName, maxLength: 40)
        guard !cleanName.isEmpty, !cleanDisplayName.isEmpty else {
            state = .failed(message: "Enter a Pack name and the name friends should see.")
            return
        }

        refreshGeneration += 1
        state = .authenticating
        do {
            let userId = try await auth.ensureAnonymousUser()
            currentUserId = userId
            state = .creating
            let invite = try await repository.createPack(
                name: cleanName,
                displayName: cleanDisplayName
            )
            Prefs.socialDisplayName = cleanDisplayName
            Prefs.activeSocialPackId = invite.pack.id
            currentInvite = invite
            try await load(packId: invite.pack.id, userId: userId)
            requestPackNotifications()
            startLiveUpdates(packId: invite.pack.id)
        } catch {
            state = .failed(message: userMessage(for: error))
        }
    }

    func joinPack(inviteValue: String, displayName: String) async {
        guard let token = PackInviteParser.token(from: inviteValue) else {
            state = .failed(message: "That invite is incomplete or invalid.")
            return
        }
        let cleanDisplayName = sanitized(displayName, maxLength: 40)
        guard !cleanDisplayName.isEmpty else {
            state = .failed(message: "Enter the name friends should see.")
            return
        }

        refreshGeneration += 1
        state = .authenticating
        do {
            let userId = try await auth.ensureAnonymousUser()
            currentUserId = userId
            state = .joining
            let pack = try await repository.joinPack(
                token: token,
                displayName: cleanDisplayName
            )
            Prefs.socialDisplayName = cleanDisplayName
            Prefs.activeSocialPackId = pack.id
            currentInvite = nil
            try await load(packId: pack.id, userId: userId)
            requestPackNotifications()
            startLiveUpdates(packId: pack.id)
        } catch {
            state = .failed(message: userMessage(for: error))
        }
    }

    func refresh() {
        guard let snapshot, let userId = currentUserId else { return }
        let generation = refreshGeneration
        state = .refreshing(snapshot)
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            defer { refreshTask = nil }
            do {
                let refreshed = try await repository.fetchSnapshot(
                    packId: snapshot.pack.id,
                    currentUserId: userId
                )
                guard generation == refreshGeneration, !Task.isCancelled else { return }
                notifyNewActivities(previous: snapshot, current: refreshed)
                state = .joined(refreshed)
                await flushOutbox()
            } catch {
                guard generation == refreshGeneration, !Task.isCancelled else { return }
                if isMissingPack(error) {
                    clearMembership()
                } else {
                    state = .offline(snapshot, message: userMessage(for: error))
                }
            }
        }
    }

    func rotateInvite() async {
        guard let pack = snapshot?.pack else { return }
        do {
            currentInvite = try await repository.rotateInvite(pack: pack)
        } catch {
            state = .offline(snapshot, message: userMessage(for: error))
        }
    }

    func leavePack() async {
        guard let packId = snapshot?.pack.id else { return }
        do {
            try await repository.leavePack(packId: packId)
            clearMembership()
        } catch {
            state = .offline(snapshot, message: userMessage(for: error))
        }
    }

    func deletePack() async {
        guard let packId = snapshot?.pack.id else { return }
        do {
            try await repository.deletePack(packId: packId)
            clearMembership()
        } catch {
            state = .offline(snapshot, message: userMessage(for: error))
        }
    }

    func updateDisplayName(_ displayName: String) async {
        guard let snapshot, let userId = currentUserId else { return }
        let cleanName = sanitized(displayName, maxLength: 40)
        guard !cleanName.isEmpty else { return }
        do {
            try await repository.updateDisplayName(
                packId: snapshot.pack.id,
                userId: userId,
                displayName: cleanName
            )
            Prefs.socialDisplayName = cleanName
            refresh()
        } catch {
            state = .offline(snapshot, message: userMessage(for: error))
        }
    }

    func recordCompletedWorkout(reps: Int) {
        guard let snapshot, let userId = currentUserId else { return }
        let pending = PendingWorkoutEvent(
            packId: snapshot.pack.id,
            userId: userId,
            reps: reps,
            setsToday: Prefs.setsToday,
            streak: Prefs.currentStreak,
            localDay: Prefs.dayString(Date()),
            completedAt: Date()
        )
        Task {
            do {
                try await outbox.enqueue(pending)
                pendingDeliveryCount = await outbox.all().count
                await flushOutbox()
            } catch {
                state = .offline(snapshot, message: "Your set is saved locally, but sharing is pending.")
            }
        }
    }

    func toggleReaction(kind: ReactionKind, activity: PackActivity) async {
        guard let snapshot, let userId = currentUserId else { return }
        let alreadyReacted = activity.reactions.contains {
            $0.userId == userId && $0.kind == kind
        }
        do {
            if alreadyReacted {
                try await repository.removeReaction(
                    kind: kind,
                    eventId: activity.event.id,
                    userId: userId
                )
            } else {
                try await repository.addReaction(
                    kind: kind,
                    eventId: activity.event.id,
                    packId: snapshot.pack.id,
                    userId: userId
                )
            }
            refresh()
        } catch {
            state = .offline(snapshot, message: userMessage(for: error))
        }
    }

    func handle(url: URL) -> String? {
        PackInviteParser.token(from: url.absoluteString)
    }

    private func load(packId: UUID, userId: UUID) async throws {
        let generation = refreshGeneration
        let loaded = try await repository.fetchSnapshot(
            packId: packId,
            currentUserId: userId
        )
        guard generation == refreshGeneration else { return }
        state = .joined(loaded)
    }

    private func flushOutbox() async {
        guard let activePackId = snapshot?.pack.id else { return }
        let events = await outbox.due()
        pendingDeliveryCount = await outbox.all().count
        for event in events {
            if event.packId != activePackId {
                try? await outbox.remove(id: event.id)
                continue
            }
            do {
                try await repository.submitWorkout(event)
                try await outbox.remove(id: event.id)
            } catch {
                try? await outbox.markFailed(id: event.id)
                break
            }
        }
        pendingDeliveryCount = await outbox.all().count
        if !events.isEmpty, pendingDeliveryCount == 0 {
            refresh()
        }
    }

    private func startPolling() {
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 120_000_000_000)
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }
    }

    private func startLiveUpdates(packId: UUID) {
        realtimeTask?.cancel()
        realtimeRefreshTask?.cancel()
        startPolling()
        realtimeTask = Task { [weak self] in
            guard let self else { return }
            let channel = SocialBackend.shared.channel("pack:\(packId.uuidString.lowercased())")
            let changes = channel.postgresChange(
                AnyAction.self,
                schema: "public",
                filter: .eq("pack_id", value: packId)
            )
            do {
                try await channel.subscribeWithError()
                for await _ in changes {
                    guard !Task.isCancelled else { break }
                    self.scheduleRealtimeRefresh()
                }
            } catch {
                guard !Task.isCancelled, let snapshot else { return }
                state = .offline(
                    snapshot,
                    message: "Live updates are reconnecting. Manual refresh still works."
                )
            }
            await SocialBackend.shared.removeChannel(channel)
        }
    }

    private func scheduleRealtimeRefresh() {
        realtimeRefreshTask?.cancel()
        realtimeRefreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    private func requestPackNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound]
        ) { _, _ in }
    }

    private func notifyNewActivities(previous: PackSnapshot, current: PackSnapshot) {
        guard !previous.activities.isEmpty else { return }
        let previousIds = Set(previous.activities.map(\.id))
        let newActivities = current.activities.filter {
            !previousIds.contains($0.id) &&
                $0.member.userId != current.currentUserId
        }
        for activity in newActivities.prefix(3) {
            let content = UNMutableNotificationContent()
            content.title = Prefs.packNotificationShowsNames
                ? "\(activity.member.displayName) finished a set"
                : "A Pack member finished a set"
            content.body = "\(activity.event.reps) squats · \(activity.event.sets) sets today"
            content.sound = Prefs.soundEnabled ? .default : nil
            content.categoryIdentifier = "PACK_ACTIVITY"
            content.userInfo = ["event_id": activity.event.id]
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(
                    identifier: "pack-event-\(activity.event.id)",
                    content: content,
                    trigger: nil
                )
            )
        }
    }

    private func clearMembership() {
        let departedPackId = snapshot?.pack.id ?? Prefs.activeSocialPackId
        refreshGeneration += 1
        refreshTask?.cancel()
        pollingTask?.cancel()
        realtimeTask?.cancel()
        realtimeRefreshTask?.cancel()
        currentInvite = nil
        Prefs.activeSocialPackId = nil
        state = .ready
        if let departedPackId {
            Task {
                try? await outbox.removeAll(packId: departedPackId)
                pendingDeliveryCount = await outbox.all().count
            }
        }
    }

    private func sanitized(_ value: String, maxLength: Int) -> String {
        String(
            value
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .filter { !$0.isNewline && !$0.isASCIIControl }
                .prefix(maxLength)
        )
    }

    private func userMessage(for error: Error) -> String {
        if let repositoryError = error as? PackRepositoryError {
            return repositoryError.localizedDescription
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return "You appear to be offline. Your local workout data is safe."
        }
        return "Pack couldn’t update. Try again in a moment."
    }

    private func isMissingPack(_ error: Error) -> Bool {
        guard let repositoryError = error as? PackRepositoryError else { return false }
        if case .packNotFound = repositoryError { return true }
        return false
    }
}

private extension Character {
    var isASCIIControl: Bool {
        unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f }
    }
}
