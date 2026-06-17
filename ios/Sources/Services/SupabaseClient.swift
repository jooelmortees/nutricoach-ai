// ============================================================
// SupabaseClient - wrapper sobre supabase-swift
// ============================================================

import Foundation
import Supabase

final class SupabaseService {
    static let shared = SupabaseService()

    let client: SupabaseClient

    private init() {
        self.client = SupabaseClient(
            supabaseURL: Config.supabaseURL,
            supabaseKey: Config.supabaseAnonKey,
            options: SupabaseClientOptions(
                auth: .init(
                    autoRefreshToken: true,
                    persistSession: true,
                    detectSessionInUrl: false
                )
            )
        )
    }
}
