// ============================================================
// Config - configuración de la app (carga de Keys/Info.plist)
// ============================================================

import Foundation

enum Config {
    /// URL del proyecto Supabase. Se inyecta en build time desde Info.plist
    /// o desde variable de entorno. En debug se lee de Info.plist.
    static let supabaseURL: URL = {
        if let str = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_URL") as? String,
           let url = URL(string: str) {
            return url
        }
        // Fallback para desarrollo
        return URL(string: "https://your-project-ref.supabase.co")!
    }()

    /// Anon key de Supabase (pública, OK en cliente)
    static let supabaseAnonKey: String = {
        if let key = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_ANON_KEY") as? String {
            return key
        }
        return "your-anon-key-here"
    }()

    /// URL base de la Edge Function chat-proxy
    static let chatProxyURL: URL = {
        supabaseURL.appending(path: "functions/v1/chat-proxy")
    }()

    /// URL base de la Edge Function hk-sync
    static let hkSyncURL: URL = {
        supabaseURL.appending(path: "functions/v1/hk-sync")
    }()

    /// URL base de la Edge Function delete-account
    static let deleteAccountURL: URL = {
        supabaseURL.appending(path: "functions/v1/delete-account")
    }()
}
