import Foundation
import Supabase

actor PackRepository {
    private struct CreatePackRequest: Encodable {
        let name: String
        let displayName: String
    }

    private struct JoinPackRequest: Encodable {
        let token: String
        let displayName: String
    }

    private struct PackRequest: Encodable {
        let packId: UUID
    }

    private struct InviteToken: Decodable {
        let token: String
        let expiresAt: Date
    }

    private struct CreatePackResponse: Decodable {
        let packId: UUID
        let invite: InviteToken
    }

    private struct JoinPackResponse: Decodable {
        let packId: UUID
        let name: String
    }

    private struct RotateInviteResponse: Decodable {
        let token: String
        let expiresAt: Date
    }

    private struct LeaveResponse: Decodable {
        let left: Bool
    }

    private struct DeleteResponse: Decodable {
        let deleted: Bool
    }

    private struct WorkoutEventInsert: Encodable {
        let clientId: UUID
        let packId: UUID
        let userId: UUID
        let occurredAt: Date
        let sets: Int
        let reps: Int
        let streak: Int

        enum CodingKeys: String, CodingKey {
            case clientId = "client_id"
            case packId = "pack_id"
            case userId = "user_id"
            case occurredAt = "occurred_at"
            case sets
            case reps
            case streak
        }
    }

    private struct ReactionInsert: Encodable {
        let packId: UUID
        let eventId: Int64
        let userId: UUID
        let kind: ReactionKind

        enum CodingKeys: String, CodingKey {
            case packId = "pack_id"
            case eventId = "event_id"
            case userId = "user_id"
            case kind
        }
    }

    private let client: SupabaseClient

    init(client: SupabaseClient = SocialBackend.shared) {
        self.client = client
    }

    func createPack(name: String, displayName: String) async throws -> PackInvite {
        let response: CreatePackResponse = try await client.functions.invoke(
            "create-pack",
            options: FunctionInvokeOptions(
                body: CreatePackRequest(name: name, displayName: displayName)
            )
        )
        let pack = try await fetchPack(id: response.packId)
        return PackInvite(
            pack: pack,
            token: response.invite.token,
            expiresAt: response.invite.expiresAt
        )
    }

    func joinPack(token: String, displayName: String) async throws -> SquatPack {
        let response: JoinPackResponse = try await client.functions.invoke(
            "join-pack",
            options: FunctionInvokeOptions(
                body: JoinPackRequest(token: token, displayName: displayName)
            )
        )
        return try await fetchPack(id: response.packId)
    }

    func rotateInvite(pack: SquatPack) async throws -> PackInvite {
        let response: RotateInviteResponse = try await client.functions.invoke(
            "rotate-invite",
            options: FunctionInvokeOptions(body: PackRequest(packId: pack.id))
        )
        return PackInvite(
            pack: pack,
            token: response.token,
            expiresAt: response.expiresAt
        )
    }

    func leavePack(packId: UUID) async throws {
        let response: LeaveResponse = try await client.functions.invoke(
            "leave-pack",
            options: FunctionInvokeOptions(body: PackRequest(packId: packId))
        )
        guard response.left else { throw PackRepositoryError.rejected }
    }

    func deletePack(packId: UUID) async throws {
        let response: DeleteResponse = try await client.functions.invoke(
            "delete-pack",
            options: FunctionInvokeOptions(body: PackRequest(packId: packId))
        )
        guard response.deleted else { throw PackRepositoryError.rejected }
    }

    func mostRecentMembership() async throws -> PackMember? {
        let rows: [PackMember] = try await client
            .from("pack_members")
            .select()
            .order("joined_at", ascending: false)
            .limit(1)
            .execute()
            .value
        return rows.first
    }

    func fetchSnapshot(packId: UUID, currentUserId: UUID) async throws -> PackSnapshot {
        let packKey = packId.uuidString.lowercased()
        async let packsRequest: [SquatPack] = client
            .from("packs")
            .select()
            .eq("id", value: packKey)
            .limit(1)
            .execute()
            .value
        async let membersRequest: [PackMember] = client
            .from("pack_members")
            .select()
            .eq("pack_id", value: packKey)
            .order("joined_at")
            .execute()
            .value
        async let eventsRequest: [WorkoutEvent] = client
            .from("workout_events")
            .select()
            .eq("pack_id", value: packKey)
            .order("occurred_at", ascending: false)
            .limit(100)
            .execute()
            .value
        async let reactionsRequest: [PackReaction] = client
            .from("reactions")
            .select()
            .eq("pack_id", value: packKey)
            .order("created_at")
            .limit(500)
            .execute()
            .value

        let (packs, members, events, reactions) = try await (
            packsRequest,
            membersRequest,
            eventsRequest,
            reactionsRequest
        )
        guard let pack = packs.first else { throw PackRepositoryError.packNotFound }

        let memberById = Dictionary(uniqueKeysWithValues: members.map { ($0.userId, $0) })
        let reactionsByEvent = Dictionary(grouping: reactions, by: \.eventId)
        let activities = events.compactMap { event -> PackActivity? in
            guard let member = memberById[event.userId] else { return nil }
            return PackActivity(
                event: event,
                member: member,
                reactions: reactionsByEvent[event.id] ?? []
            )
        }
        return PackSnapshot(
            pack: pack,
            currentUserId: currentUserId,
            members: members,
            activities: activities,
            refreshedAt: Date()
        )
    }

    func updateDisplayName(packId: UUID, userId: UUID, displayName: String) async throws {
        struct Update: Encodable {
            let displayName: String
            enum CodingKeys: String, CodingKey {
                case displayName = "display_name"
            }
        }

        try await client
            .from("pack_members")
            .update(Update(displayName: displayName))
            .eq("pack_id", value: packId.uuidString.lowercased())
            .eq("user_id", value: userId.uuidString.lowercased())
            .execute()
    }

    func submitWorkout(_ pending: PendingWorkoutEvent) async throws {
        let event = WorkoutEventInsert(
            clientId: pending.id,
            packId: pending.packId,
            userId: pending.userId,
            occurredAt: pending.completedAt,
            sets: pending.setsToday,
            reps: pending.reps,
            streak: pending.streak
        )
        try await client
            .from("workout_events")
            .upsert(event, onConflict: "user_id,client_id", ignoreDuplicates: true)
            .execute()
    }

    func addReaction(
        kind: ReactionKind,
        eventId: Int64,
        packId: UUID,
        userId: UUID
    ) async throws {
        let reaction = ReactionInsert(
            packId: packId,
            eventId: eventId,
            userId: userId,
            kind: kind
        )
        try await client
            .from("reactions")
            .upsert(
                reaction,
                onConflict: "event_id,user_id,kind",
                ignoreDuplicates: true
            )
            .execute()
    }

    func removeReaction(
        kind: ReactionKind,
        eventId: Int64,
        userId: UUID
    ) async throws {
        try await client
            .from("reactions")
            .delete()
            .eq("event_id", value: Int(eventId))
            .eq("user_id", value: userId.uuidString.lowercased())
            .eq("kind", value: kind.rawValue)
            .execute()
    }

    private func fetchPack(id: UUID) async throws -> SquatPack {
        let rows: [SquatPack] = try await client
            .from("packs")
            .select()
            .eq("id", value: id.uuidString.lowercased())
            .limit(1)
            .execute()
            .value
        guard let pack = rows.first else { throw PackRepositoryError.packNotFound }
        return pack
    }
}

enum PackRepositoryError: LocalizedError {
    case packNotFound
    case rejected

    var errorDescription: String? {
        switch self {
        case .packNotFound:
            return "That Pack is no longer available."
        case .rejected:
            return "The Pack request was not accepted."
        }
    }
}
