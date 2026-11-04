// AuthManager.swift
// Email + password accounts backed by Supabase Auth (GoTrue REST API). The session lives in the
// Keychain, is refreshed before it expires, and is re-checked against the server whenever the app
// becomes active, so a deleted or banned account is signed out.

import Foundation
import Security

struct AuthSession: Codable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var email: String
}

enum AuthError: LocalizedError {
    case message(String)
    case network
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .message(let m): return m
        case .network: return "Couldn't reach the server. Check your connection and try again."
        case .notConfigured: return "Dazey X isn't connected to its account server yet."
        }
    }
}

enum SignUpResult {
    case signedIn
    case confirmEmail
}

@MainActor
final class AuthManager: ObservableObject {
    enum State: Equatable {
        case loading
        case signedOut
        case signedIn(email: String)
    }

    @Published private(set) var state: State = .loading

    private var session: AuthSession?
    private var refreshTask: Task<Void, Never>?

    init() {
        Task { await restore() }
    }

    // MARK: Public API

    func signIn(email: String, password: String) async throws {
        let json = try await post("token", query: [URLQueryItem(name: "grant_type", value: "password")],
                                  body: ["email": email, "password": password])
        guard let s = Self.session(from: json, fallbackEmail: email) else {
            throw AuthError.message("Unexpected response from the server.")
        }
        apply(s)
    }

    func signUp(email: String, password: String) async throws -> SignUpResult {
        let json = try await post("signup", body: ["email": email, "password": password])
        // With "Confirm email" on, Supabase returns the user without a session until the link is opened.
        if let s = Self.session(from: json, fallbackEmail: email) {
            apply(s)
            return .signedIn
        }
        return .confirmEmail
    }

    func sendPasswordReset(email: String) async throws {
        _ = try await post("recover", body: ["email": email])
    }

    func signOut() {
        if let token = session?.accessToken {
            Task { _ = try? await self.post("logout", body: [:], bearer: token) }
        }
        clear()
    }

    // Called when the app returns to the foreground.
    func revalidate() async {
        guard session != nil else { return }
        await refreshIfNeeded(force: false)
        guard let token = session?.accessToken else { return }
        do {
            _ = try await send("user", method: "GET", body: nil, bearer: token)
        } catch AuthError.message(_) {
            clear()
        } catch {
            // Offline: keep the session until it actually expires.
        }
    }

    // MARK: Session lifecycle

    private func restore() async {
        guard SupabaseConfig.isConfigured, let stored = Keychain.loadSession() else {
            state = .signedOut
            return
        }
        session = stored
        await refreshIfNeeded(force: false)
        if session != nil {
            state = .signedIn(email: session!.email)
            scheduleRefresh()
            await revalidate()
        }
    }

    private func refreshIfNeeded(force: Bool) async {
        guard let current = session else { return }
        if !force && current.expiresAt.timeIntervalSinceNow > 120 { return }
        do {
            let json = try await post("token", query: [URLQueryItem(name: "grant_type", value: "refresh_token")],
                                      body: ["refresh_token": current.refreshToken])
            if let s = Self.session(from: json, fallbackEmail: current.email) {
                apply(s)
            } else {
                clear()
            }
        } catch AuthError.message(_) {
            clear()          // refresh token revoked / user removed
        } catch {
            if current.expiresAt <= Date() { clear() }
        }
    }

    private func apply(_ s: AuthSession) {
        session = s
        Keychain.saveSession(s)
        state = .signedIn(email: s.email)
        scheduleRefresh()
    }

    private func clear() {
        refreshTask?.cancel()
        refreshTask = nil
        session = nil
        Keychain.deleteSession()
        state = .signedOut
    }

    private func scheduleRefresh() {
        refreshTask?.cancel()
        guard let expiresAt = session?.expiresAt else { return }
        let delay = max(5, expiresAt.timeIntervalSinceNow - 120)
        refreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            await self.refreshIfNeeded(force: true)
        }
    }

    // MARK: Networking

    private func post(_ path: String, query: [URLQueryItem] = [], body: [String: Any],
                      bearer: String? = nil) async throws -> [String: Any] {
        try await send(path, query: query, method: "POST", body: body, bearer: bearer)
    }

    private func send(_ path: String, query: [URLQueryItem] = [], method: String,
                      body: [String: Any]?, bearer: String?) async throws -> [String: Any] {
        guard SupabaseConfig.isConfigured else { throw AuthError.notConfigured }

        var comps = URLComponents(url: SupabaseConfig.url.appendingPathComponent("auth/v1/\(path)"),
                                  resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }

        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        req.timeoutInterval = 20
        req.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(bearer ?? SupabaseConfig.anonKey)", forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw AuthError.network
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(status) else {
            if status >= 500 || status == 0 { throw AuthError.network }
            throw AuthError.message(Self.errorMessage(from: json, status: status))
        }
        return json
    }

    private static func errorMessage(from json: [String: Any], status: Int) -> String {
        let raw = (json["msg"] as? String)
            ?? (json["error_description"] as? String)
            ?? (json["message"] as? String)
            ?? (json["error"] as? String)
            ?? "Request failed (\(status))."
        switch raw.lowercased() {
        case let m where m.contains("invalid login credentials"):
            return "Wrong email or password."
        case let m where m.contains("email not confirmed"):
            return "Confirm your email first — check your inbox for the link."
        case let m where m.contains("already registered"):
            return "An account with this email already exists. Sign in instead."
        default:
            return raw
        }
    }

    private static func session(from json: [String: Any], fallbackEmail: String) -> AuthSession? {
        guard let access = json["access_token"] as? String,
              let refresh = json["refresh_token"] as? String else { return nil }
        let expiresAt: Date
        if let at = json["expires_at"] as? Double {
            expiresAt = Date(timeIntervalSince1970: at)
        } else {
            expiresAt = Date().addingTimeInterval((json["expires_in"] as? Double) ?? 3600)
        }
        let email = ((json["user"] as? [String: Any])?["email"] as? String) ?? fallbackEmail
        return AuthSession(accessToken: access, refreshToken: refresh, expiresAt: expiresAt, email: email)
    }
}

// MARK: - Keychain

private enum Keychain {
    private static let service = "com.bossing.dazeyx.auth"
    private static let account = "session"

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func saveSession(_ session: AuthSession) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        SecItemDelete(baseQuery as CFDictionary)
        var add = baseQuery
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func loadSession() -> AuthSession? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(AuthSession.self, from: data)
    }

    static func deleteSession() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
