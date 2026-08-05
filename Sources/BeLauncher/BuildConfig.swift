import Foundation

/// Build-time constants. The Supabase anon key is public by design — it is the same key the
/// landing page ships in its JavaScript, and every table behind it is protected by RLS.
/// It can still be overridden from .env for a staging server.
enum BuildConfig {
    static let supabaseAnonKey = "__SUPABASE_ANON_KEY__"
}
