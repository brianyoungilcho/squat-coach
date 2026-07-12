import Foundation

enum PackRole: String, Codable, Sendable {
    case owner
    case member
}

enum ReactionKind: String, CaseIterable, Codable, Sendable {
    case cheer
    case strong
    case clap
    case fire

    var label: String {
        switch self {
        case .cheer:
            return "Cheer"
        case .strong:
            return "Strong"
        case .clap:
            return "Clap"
        case .fire:
            return "Fire"
        }
    }

    var symbolName: String {
        switch self {
        case .cheer:
            return "hands.clap"
        case .strong:
            return "figure.strengthtraining.functional"
        case .clap:
            return "hands.clap"
        case .fire:
            return "flame"
        }
    }
}

struct SquatPack: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let name: String
    let ownerId: UUID
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case ownerId = "owner_id"
        case createdAt = "created_at"
    }
}

struct PackMember: Codable, Equatable, Identifiable, Sendable {
    let packId: UUID
    let userId: UUID
    let displayName: String
    let role: PackRole
    let joinedAt: Date

    var id: UUID { userId }

    enum CodingKeys: String, CodingKey {
        case packId = "pack_id"
        case userId = "user_id"
        case displayName = "display_name"
        case role
        case joinedAt = "joined_at"
    }
}

struct WorkoutEvent: Codable, Equatable, Identifiable, Sendable {
    let id: Int64
    let clientId: UUID
    let packId: UUID
    let userId: UUID
    let reps: Int
    let sets: Int
    let streak: Int
    let occurredAt: Date
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case clientId = "client_id"
        case packId = "pack_id"
        case userId = "user_id"
        case reps
        case sets
        case streak
        case occurredAt = "occurred_at"
        case createdAt = "created_at"
    }
}

struct PackReaction: Codable, Equatable, Identifiable, Sendable {
    let id: Int64
    let eventId: Int64
    let packId: UUID
    let userId: UUID
    let kind: ReactionKind
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case eventId = "event_id"
        case packId = "pack_id"
        case userId = "user_id"
        case kind
        case createdAt = "created_at"
    }
}

struct PackActivity: Equatable, Identifiable, Sendable {
    let event: WorkoutEvent
    let member: PackMember
    let reactions: [PackReaction]

    var id: Int64 { event.id }
}

struct PackSnapshot: Equatable, Sendable {
    let pack: SquatPack
    let currentUserId: UUID
    let members: [PackMember]
    let activities: [PackActivity]
    let refreshedAt: Date
}

struct PackInvite: Codable, Equatable, Sendable {
    let pack: SquatPack
    let token: String
    let expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case pack
        case token
        case expiresAt = "expires_at"
    }

    var url: URL? {
        var components = URLComponents()
        components.scheme = "squatcoach"
        components.host = "join"
        components.path = "/\(token)"
        return components.url
    }
}

enum PackLoadState: Equatable {
    case disconnected
    case authenticating
    case ready
    case creating
    case joining
    case joined(PackSnapshot)
    case refreshing(PackSnapshot)
    case offline(PackSnapshot?, message: String)
    case failed(message: String)
}

enum PackInviteParser {
    static func token(from value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), url.scheme?.lowercased() == "squatcoach",
           url.host?.lowercased() == "join" {
            let token = url.pathComponents.dropFirst().first ?? ""
            return valid(token)
        }
        return valid(trimmed)
    }

    private static func valid(_ raw: String) -> String? {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.utf8.count == 43,
              token.utf8.allSatisfy({
                  (48...57).contains($0) ||
                      (65...90).contains($0) ||
                      (97...122).contains($0) ||
                      $0 == 45 ||
                      $0 == 95
              })
        else { return nil }
        return token
    }
}
