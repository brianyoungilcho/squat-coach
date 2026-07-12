import Foundation

struct PendingWorkoutEvent: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let packId: UUID
    let userId: UUID
    let reps: Int
    let setsToday: Int
    let streak: Int
    let localDay: String
    let completedAt: Date
    var attempts: Int
    var nextAttemptAt: Date

    init(
        id: UUID = UUID(),
        packId: UUID,
        userId: UUID,
        reps: Int,
        setsToday: Int,
        streak: Int,
        localDay: String,
        completedAt: Date,
        attempts: Int = 0,
        nextAttemptAt: Date = .distantPast
    ) {
        self.id = id
        self.packId = packId
        self.userId = userId
        self.reps = reps
        self.setsToday = setsToday
        self.streak = streak
        self.localDay = localDay
        self.completedAt = completedAt
        self.attempts = attempts
        self.nextAttemptAt = nextAttemptAt
    }
}

actor SocialOutbox {
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var events: [PendingWorkoutEvent]

    init(fileURL: URL? = nil) {
        let resolvedURL = fileURL ?? Self.defaultFileURL()
        self.fileURL = resolvedURL

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        self.events = Self.load(from: resolvedURL, decoder: decoder)
    }

    func enqueue(_ event: PendingWorkoutEvent) throws {
        guard !events.contains(where: { $0.id == event.id }) else { return }
        events.append(event)
        try persist()
    }

    func due(at now: Date = Date()) -> [PendingWorkoutEvent] {
        events
            .filter { $0.nextAttemptAt <= now }
            .sorted { $0.completedAt < $1.completedAt }
    }

    func remove(id: UUID) throws {
        events.removeAll { $0.id == id }
        try persist()
    }

    func removeAll(packId: UUID) throws {
        events.removeAll { $0.packId == packId }
        try persist()
    }

    func markFailed(id: UUID, now: Date = Date()) throws {
        guard let index = events.firstIndex(where: { $0.id == id }) else { return }
        events[index].attempts += 1
        let exponent = min(events[index].attempts, 8)
        let baseDelay = min(pow(2, Double(exponent)), 300)
        let jitter = Double.random(in: 0...(baseDelay * 0.2))
        events[index].nextAttemptAt = now.addingTimeInterval(baseDelay + jitter)
        try persist()
    }

    func all() -> [PendingWorkoutEvent] {
        events.sorted { $0.completedAt < $1.completedAt }
    }

    private func persist() throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let data = try encoder.encode(events)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }

    private static func load(from fileURL: URL, decoder: JSONDecoder) -> [PendingWorkoutEvent] {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? decoder.decode([PendingWorkoutEvent].self, from: data)
        else { return [] }
        return decoded
    }

    private static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
        return base
            .appendingPathComponent("SquatCoach", isDirectory: true)
            .appendingPathComponent("social-outbox.json", isDirectory: false)
    }
}
