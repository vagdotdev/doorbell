import Foundation

/// Where the app points. Environment variables win; a `.env` in the working
/// directory fills in the rest (development). No backend config → mock.
///
///   DOORBELL_BACKEND=convex     the real graph and media, on Convex (CONVEX_URL)
///   DOORBELL_BACKEND=supabase   the previous stack (SUPABASE_URL / SUPABASE_ANON_KEY)
///   DOORBELL_PROFILE=b          separate session + defaults, for a second account on one Mac
struct AppConfig: Sendable {
    let convexURL: URL?
    let supabaseURL: URL?
    let supabaseAnonKey: String?
    let profile: String
    let useConvex: Bool
    let useSupabase: Bool
    /// A real backend with real media, as opposed to the mock hallway.
    var isLive: Bool { useConvex || useSupabase }

    static let current = AppConfig()

    private init() {
        var values = ProcessInfo.processInfo.environment
        // `swift run` finds .env in the working directory; a bundle built by
        // scripts/bundle.sh carries a copy in Contents/Resources.
        // `npx convex dev` writes CONVEX_URL to .env.local; it is read too.
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let candidates = [
            cwd.appendingPathComponent(".env"),
            cwd.appendingPathComponent(".env.local"),
            Bundle.main.resourceURL?.appendingPathComponent(".env"),
            Bundle.main.resourceURL?.appendingPathComponent(".env.local"),
        ].compactMap { $0 }
        for dotenv in candidates where FileManager.default.fileExists(atPath: dotenv.path) {
            guard let text = try? String(contentsOf: dotenv, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "=") else { continue }
                let key = String(trimmed[..<eq])
                let value = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .init(charactersIn: "\"' "))
                if values[key] == nil, !value.isEmpty { values[key] = value }
            }
        }
        convexURL = values["CONVEX_URL"].flatMap(URL.init(string:))
        supabaseURL = values["SUPABASE_URL"].flatMap(URL.init(string:))
        supabaseAnonKey = values["SUPABASE_ANON_KEY"]
        profile = values["DOORBELL_PROFILE"] ?? "default"
        useConvex = values["DOORBELL_BACKEND"] == "convex" && convexURL != nil
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
