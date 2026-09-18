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
    /// Shared group password for `{handle}@doorbell.local` join. Not shown in the UI.
    let joinSecret: String
    let useConvex: Bool
    let useSupabase: Bool
    /// A real backend with real media, as opposed to the mock hallway.
    var isLive: Bool { useConvex || useSupabase }

    static let current = AppConfig()

    private init() {
        let values = Self.resolvedValues(environment: ProcessInfo.processInfo.environment,
            workingDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
            resources: Bundle.main.resourceURL, bundled: Bundle.main.bundleURL.pathExtension == "app")
        convexURL = values["CONVEX_URL"].flatMap(URL.init(string:))
        supabaseURL = values["SUPABASE_URL"].flatMap(URL.init(string:))
        supabaseAnonKey = values["SUPABASE_ANON_KEY"]
        profile = values["DOORBELL_PROFILE"] ?? "default"
        joinSecret = values["DOORBELL_JOIN_SECRET"] ?? "doorbell"
        useConvex = values["DOORBELL_BACKEND"] == "convex" && convexURL != nil
        useSupabase = values["DOORBELL_BACKEND"] == "supabase" && supabaseURL != nil && supabaseAnonKey != nil
        Self.dropStaleSession(for: convexURL, profile: values["DOORBELL_PROFILE"] ?? "default")
    }

    /// Installed apps use their signed configuration; shell env and working-directory
    /// `.env` must not silently send an installed client to a different deployment.
    static func resolvedValues(environment: [String: String], workingDirectory: URL,
                               resources: URL?, bundled: Bool) -> [String: String] {
        var fromFiles: [String: String] = [:]
        var candidates: [URL] = bundled ? [] : [
            workingDirectory.appendingPathComponent(".env"),
            workingDirectory.appendingPathComponent(".env.local"),
        ]
        if let resources {
            candidates.append(resources.appendingPathComponent(".env"))
            if !bundled { candidates.append(resources.appendingPathComponent(".env.local")) }
        }
        for dotenv in candidates {
            for (key, value) in parseDotenv(at: dotenv) where fromFiles[key] == nil {
                fromFiles[key] = value
            }
        }

        var values = environment
        for (key, value) in fromFiles where values[key] == nil {
            values[key] = value
        }
        if bundled {
            for key in ["CONVEX_URL", "DOORBELL_BACKEND", "SUPABASE_URL", "SUPABASE_ANON_KEY"] {
                if let value = fromFiles[key], !value.isEmpty { values[key] = value }
            }
        }
        return values
    }

    private static func parseDotenv(at url: URL) -> [String: String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var out: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .init(charactersIn: "\"' "))
            if !key.isEmpty, !value.isEmpty { out[key] = value }
        }
        return out
    }

    /// Legacy plaintext sessions predate deployment-scoped Keychain storage. A
    /// missing marker is normal on upgrade; preserve the token so it can migrate
    /// and let the configured backend validate its refresh token.
    private static func dropStaleSession(for convexURL: URL?, profile: String) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        prepareLegacySession(for: convexURL,
            directory: base.appendingPathComponent("Doorbell/\(profile)", isDirectory: true))
    }

    static func prepareLegacySession(for convexURL: URL?, directory: URL) {
        guard let convexURL else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let marker = directory.appendingPathComponent("convex-url.txt")
        let expected = deploymentIdentity(convexURL)
        if let previous = try? String(contentsOf: marker, encoding: .utf8),
           let previousURL = URL(string: previous.trimmingCharacters(in: .whitespacesAndNewlines)),
           previousURL.host != nil, ["http", "https"].contains(previousURL.scheme?.lowercased() ?? ""),
           deploymentIdentity(previousURL) != expected {
            // Only a known backend change invalidates an unscoped legacy file.
            // Keychain entries already belong to their deployment and stay intact.
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("convex-session.json"))
        }
        try? expected.write(to: marker, atomically: true, encoding: .utf8)
    }

    private static func deploymentIdentity(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        if components.path == "/" { components.path = "" }
        if (components.scheme == "https" && components.port == 443) ||
            (components.scheme == "http" && components.port == 80) { components.port = nil }
        return components.string ?? url.absoluteString
    }

    /// Per-profile scratch: session file, mock graph.
    var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Doorbell/\(profile)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    var sessionFile: URL { supportDirectory.appendingPathComponent("convex-session.json") }

    /// A saved Convex session means this Mac has been through Join at least once.
    static var hasStoredSession: Bool {
        guard let url = current.convexURL else { return false }
        let storage = MigratingAuthStorage(directory: current.supportDirectory,
            profile: "convex-\(current.profile)-\(url.host ?? "local")")
        return (try? storage.retrieve(key: "convex-session")) != nil
    }
}
