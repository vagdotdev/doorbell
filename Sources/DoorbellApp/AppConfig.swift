import Foundation

/// Where the app points. Environment variables win; a `.env` in the working
/// directory fills in the rest (development). No backend config → mock.
///
///   DOORBELL_BACKEND=supabase   use the real graph and media
///   DOORBELL_PROFILE=b          separate session + defaults, for a second account on one Mac
///   SUPABASE_URL / SUPABASE_ANON_KEY
struct AppConfig: Sendable {
    let supabaseURL: URL?
    let supabaseAnonKey: String?
    let profile: String
    let useSupabase: Bool

    static let current = AppConfig()

    private init() {
        var values = ProcessInfo.processInfo.environment
        // `swift run` finds .env in the working directory; a bundle built by
        // scripts/bundle.sh carries a copy in Contents/Resources.
        let candidates = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".env"),
            Bundle.main.resourceURL?.appendingPathComponent(".env"),
        ].compactMap { $0 }
        if let dotenv = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
           let text = try? String(contentsOf: dotenv, encoding: .utf8) {
            for line in text.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "=") else { continue }
                let key = String(trimmed[..<eq])
                let value = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .init(charactersIn: "\"' "))
                if values[key] == nil, !value.isEmpty { values[key] = value }
            }
        }
        supabaseURL = values["SUPABASE_URL"].flatMap(URL.init(string:))
        supabaseAnonKey = values["SUPABASE_ANON_KEY"]
        profile = values["DOORBELL_PROFILE"] ?? "default"
        useSupabase = values["DOORBELL_BACKEND"] == "supabase" && supabaseURL != nil && supabaseAnonKey != nil
    }

    /// Per-profile scratch: session file, mock graph.
    var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Doorbell/\(profile)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
