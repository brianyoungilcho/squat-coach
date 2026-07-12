import Foundation
import Supabase

actor AuthSession {
    private let client: SupabaseClient

    init(client: SupabaseClient = SocialBackend.shared) {
        self.client = client
    }

    func currentUserId() async throws -> UUID? {
        guard client.auth.currentSession != nil else { return nil }
        return try await client.auth.session.user.id
    }

    func ensureAnonymousUser() async throws -> UUID {
        if client.auth.currentSession != nil {
            do {
                return try await client.auth.session.user.id
            } catch {
                try? await client.auth.signOut(scope: .local)
            }
        }
        let session = try await client.auth.signInAnonymously()
        return session.user.id
    }

    func signOutLocally() async throws {
        try await client.auth.signOut(scope: .local)
    }
}
