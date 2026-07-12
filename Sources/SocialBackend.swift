import Foundation
import Supabase

enum SocialBackend {
    static let defaultBaseURL = URL(string: "https://dpkyrftbxuhwwwtaftga.supabase.co")!
    static let defaultPublishableKey = "sb_publishable_xF8Tsxl_TQU04C6ArgRvvw_TFZQ1GUZ"

    static let shared = makeClient(
        baseURL: ProcessInfo.processInfo.environment["SQUAT_COACH_SUPABASE_URL"]
            .flatMap(URL.init(string:)) ?? defaultBaseURL,
        publishableKey: ProcessInfo.processInfo.environment["SQUAT_COACH_SUPABASE_KEY"]
            ?? defaultPublishableKey
    )

    static func makeClient(
        baseURL: URL = defaultBaseURL,
        publishableKey: String = defaultPublishableKey
    ) -> SupabaseClient {
        let databaseDecoder = JSONDecoder()
        databaseDecoder.dateDecodingStrategy = .iso8601

        let functionDecoder = JSONDecoder()
        functionDecoder.dateDecodingStrategy = .iso8601

        return SupabaseClient(
            supabaseURL: baseURL,
            supabaseKey: publishableKey,
            options: SupabaseClientOptions(
                db: .init(decoder: databaseDecoder),
                auth: .init(
                    storage: KeychainLocalStorage(
                        service: "com.squatcoach.app.supabase"
                    ),
                    emitLocalSessionAsInitialSession: true
                ),
                global: .init(headers: ["x-client-info": "squat-coach-macos"]),
                functions: .init(decoder: functionDecoder)
            )
        )
    }
}
