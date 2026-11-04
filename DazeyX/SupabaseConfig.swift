import Foundation

// Supabase project used for Dazey X accounts. The anon/publishable key is meant to ship in client
// apps; never put the service_role / secret key here.
enum SupabaseConfig {
    static let url = URL(string: "https://cjkwhhfzeidnzelyvbwx.supabase.co")!
    static let anonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImNqa3doaGZ6ZWlkbnplbHl2Ynd4Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTM3ODc1NTMsImV4cCI6MjEwOTM2MzU1M30.NnwM0gqbF1jhu2QY9WjnQsk2rrFAf3VPoBqkpi3dsPI"

    static var isConfigured: Bool {
        !url.absoluteString.contains("YOUR-PROJECT-REF") && !anonKey.hasPrefix("YOUR-")
    }
}
