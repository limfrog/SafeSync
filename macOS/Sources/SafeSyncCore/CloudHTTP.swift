import Foundation

public struct APIError: LocalizedError, Sendable {
    public var status: Int
    public var summary: String
    public var errorDescription: String? { "클라우드 요청 실패 (\(status)): \(summary)" }
}
public enum HTTP {
    public static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 120; config.timeoutIntervalForResource = 3600
        config.httpCookieStorage = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()
    public static func form(_ values: [String: String]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return Data(values.sorted { $0.key < $1.key }.map { "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)" }.joined(separator: "&").utf8)
    }
    public static func url(_ base: String, query: [String: String] = [:]) -> URL {
        var components = URLComponents(string: base)!
        if !query.isEmpty { components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        return components.url!
    }
    public static func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]) }
    public static func object(_ data: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw BackupError.unsafe("클라우드 응답 형식이 올바르지 않습니다.") }; return value
    }
    public static func send(_ request: URLRequest, accepted: Set<Int> = Set(200...299)) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw BackupError.unsafe("HTTP 응답을 확인할 수 없습니다.") }
        guard accepted.contains(http.statusCode) else {
            // Never include token endpoints, Authorization headers or resumable URLs in errors.
            throw APIError(status: http.statusCode, summary: http.statusCode == 401 ? "인증이 만료되었습니다. 계정을 다시 연결하세요." : http.statusCode == 409 ? "원격 파일 상태가 달라졌습니다. 다시 검사하세요." : http.statusCode == 429 ? "요청 한도를 초과했습니다. 잠시 후 재시도합니다." : "서비스 응답을 확인하고 다시 시도하세요.")
        }
        return (data, http)
    }
    public static func date(_ string: String?) -> Date {
        guard let string else { return .distantPast }
        let format = ISO8601DateFormatter(); format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return format.date(from: string) ?? ISO8601DateFormatter().date(from: string) ?? .distantPast
    }
    public static func dateString(_ date: Date, fractional: Bool = false) -> String {
        let formatter = ISO8601DateFormatter()
        if fractional { formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds] }
        return formatter.string(from: date)
    }
}
public actor CloudAuthorization {
    public static let shared = CloudAuthorization()
    private var refreshes: [UUID: Task<String, Error>] = [:]
    public func token(_ account: CloudAccount, forceRefresh: Bool = false) async throws -> String {
        if let task = refreshes[account.id] { return try await task.value }
        let secret = try CredentialVault.read(account: account.id)
        if !forceRefresh, secret.expiresAt.timeIntervalSinceNow > 90, !secret.accessToken.isEmpty { return secret.accessToken }
        guard !secret.refreshToken.isEmpty else { throw BackupError.unsafe("클라우드 계정을 다시 연결하세요.") }
        let task = Task<String, Error> {
            var params = ["grant_type": "refresh_token", "refresh_token": secret.refreshToken, "client_id": account.clientID]
            if account.provider == .googleDrive, !secret.clientSecret.isEmpty { params["client_secret"] = secret.clientSecret }
            var request = URLRequest(url: URL(string: account.provider == .dropbox ? "https://api.dropboxapi.com/oauth2/token" : "https://oauth2.googleapis.com/token")!)
            request.httpMethod = "POST"; request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type"); request.httpBody = HTTP.form(params)
            let (data, _) = try await HTTP.send(request); let json = try HTTP.object(data)
            guard let access = json["access_token"] as? String else { throw BackupError.unsafe("인증 토큰 응답이 올바르지 않습니다.") }
            var updated = secret; updated.accessToken = access; updated.expiresAt = Date().addingTimeInterval((json["expires_in"] as? Double) ?? 3600)
            if let refresh = json["refresh_token"] as? String { updated.refreshToken = refresh }
            try CredentialVault.save(updated, account: account.id)
            return access
        }
        refreshes[account.id] = task
        defer { refreshes.removeValue(forKey: account.id) }
        return try await task.value
    }
    public func download(_ account: CloudAccount, url: URL, to destination: URL, method: String = "GET", headers: [String: String] = [:]) async throws {
        for attempt in 0...1 {
            var request = URLRequest(url: url); request.httpMethod = method
            for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
            request.setValue("Bearer \(try await token(account, forceRefresh: attempt == 1))", forHTTPHeaderField: "Authorization")
            let (temporary, response) = try await HTTP.session.download(for: request)
            defer { try? FileManager.default.removeItem(at: temporary) }
            guard let http = response as? HTTPURLResponse else { throw BackupError.unsafe("다운로드 응답이 없습니다.") }
            if http.statusCode == 401 && attempt == 0 { continue }
            guard (200...299).contains(http.statusCode) else { throw APIError(status: http.statusCode, summary: "파일 다운로드를 완료하지 못했습니다.") }
            try Task.checkCancellation()
            try FileManager.default.moveItem(at: temporary, to: destination); return
        }
        throw BackupError.unsafe("클라우드 인증 갱신에 실패했습니다.")
    }
    public func request(_ account: CloudAccount, url: URL, method: String = "GET", body: Data? = nil, headers: [String: String] = [:], accepted: Set<Int> = Set(200...299)) async throws -> (Data, HTTPURLResponse) {
        for attempt in 0...1 {
            var request = URLRequest(url: url); request.httpMethod = method; request.httpBody = body
            for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
            request.setValue("Bearer \(try await token(account, forceRefresh: attempt == 1))", forHTTPHeaderField: "Authorization")
            do { return try await HTTP.send(request, accepted: accepted) }
            catch let error as APIError where error.status == 401 && attempt == 0 { continue }
        }
        throw BackupError.unsafe("클라우드 인증 갱신에 실패했습니다.")
    }
}
