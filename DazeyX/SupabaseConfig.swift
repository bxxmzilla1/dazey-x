import Foundation

// Supabase project used for Dazey X accounts. The anon/publishable key is meant to ship in client
// apps; never put the service_role / secret key here.
enum SupabaseConfig {
    static let url = URL(string: "https://YOUR-PROJECT-REF.supabase.co")!
    static let anonKey = "YOUR-ANON-OR-PUBLISHABLE-KEY"

    static var isConfigured: Bool {
        !url.absoluteString.contains("YOUR-PROJECT-REF") && !anonKey.hasPrefix("YOUR-")
    }
}
