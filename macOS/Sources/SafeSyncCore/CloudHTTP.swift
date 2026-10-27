import Foundation

public struct APIError: LocalizedError, Sendable {
    public var status: Int
    public var summary: String
    public var code: String? = nil
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
        let started = ProcessInfo.processInfo.systemUptime
        let operation = endpointForLog(request)
        let trace = OperationLog.isEnabled ? HTTPTaskTrace(operation: operation) : nil
        defer { trace?.finish() }
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request, delegate: trace) }
        catch { OperationLog.event("http.end", operation, ms: (ProcessInfo.processInfo.systemUptime - started) * 1000, error: error); throw error }
        guard let http = response as? HTTPURLResponse else { throw BackupError.unsafe("HTTP 응답을 확인할 수 없습니다.") }
        OperationLog.event("http.end", operation, bytes: Int64(request.httpBody?.count ?? 0), total: data.count, status: http.statusCode, ms: (ProcessInfo.processInfo.systemUptime - started) * 1000)
        guard accepted.contains(http.statusCode) else {
            // Never include token endpoints, Authorization headers or resumable URLs in errors.
            throw responseError(status: http.statusCode, url: request.url!, data: data)
        }
        return (data, http)
    }
    private static func endpointForLog(_ request: URLRequest) -> String { (request.httpMethod ?? "GET") + " " + (request.url.map(OperationLog.endpoint) ?? "unknown") }
    /// Only tagged error codes are inspected. Never echo error_summary, paths or tokens.
    public static func responseError(status: Int, url: URL, data: Data) -> APIError {
        var summary = status == 401 ? "인증이 만료되었습니다. 계정을 다시 연결하세요." : status == 409 ? "원격 요청을 처리하지 못했습니다. 경로·이름·권한을 확인하세요." : status == 429 ? "요청 한도를 초과했습니다. 잠시 후 재시도합니다." : "서비스 응답을 확인하고 다시 시도하세요."
        var code: String?
        if ["api.dropboxapi.com", "content.dropboxapi.com"].contains(url.host ?? ""),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           var tagged = object["error"] as? [String: Any] {
            let allowed = Set(["path", "from_lookup", "from_write", "to", "disallowed_name", "not_found", "not_file", "not_folder", "conflict", "file", "folder", "no_write_permission", "insufficient_space", "reset", "other"])
            var tags: [String] = []
            for _ in 0..<5 {
                guard let tag = tagged[".tag"] as? String, allowed.contains(tag) else { break }
                tags.append(tag)
                guard let next = tagged[tag] as? [String: Any] else { break }
                tagged = next
            }
            if !tags.isEmpty { code = tags.joined(separator: "/") }
            if status == 409 {
                if tags.contains("disallowed_name") { summary = "Dropbox가 지원하지 않는 파일 이름입니다. .DS_Store·desktop.ini·Thumbs.db는 자동 제외됩니다." }
                else if tags.contains("not_found") { summary = "Dropbox에서 요청한 파일 또는 폴더를 찾을 수 없습니다. 위치와 접근 권한을 확인하세요." }
                else if tags.contains("no_write_permission") { summary = "Dropbox 폴더에 쓰기 권한이 없습니다." }
                else if tags.contains("insufficient_space") { summary = "Dropbox 저장 공간이 부족합니다." }
                else if tags.contains("conflict") { summary = "Dropbox 대상 위치에 같은 이름의 항목이 있습니다. 기존 사본을 보존했습니다." }
                else if tags.contains("reset") { summary = "Dropbox 변경 목록이 만료되었습니다. 전체 목록을 다시 확인합니다." }
            }
        }
        return APIError(status: status, summary: summary, code: code)
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
        if account.provider == .googleDrive { try GoogleFileAccess.validateAccount(account); try GoogleFileAccess.validateScope(secret.grantedScope) }
        if !forceRefresh, secret.expiresAt.timeIntervalSinceNow > 90, !secret.accessToken.isEmpty { return secret.accessToken }
        guard !secret.refreshToken.isEmpty else { throw BackupError.unsafe("클라우드 계정을 다시 연결하세요.") }
        let task = Task<String, Error> {
            let timing = OperationLog.measure("prepare.oauth_token_exchange"); defer { timing.end() }
            var params = ["grant_type": "refresh_token", "refresh_token": secret.refreshToken, "client_id": account.clientID]
            if account.provider == .googleDrive, !secret.clientSecret.isEmpty { params["client_secret"] = secret.clientSecret }
            var request = URLRequest(url: URL(string: account.provider == .dropbox ? "https://api.dropboxapi.com/oauth2/token" : "https://oauth2.googleapis.com/token")!)
            request.httpMethod = "POST"; request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type"); request.httpBody = HTTP.form(params)
            let (data, _) = try await HTTP.send(request); let json = try HTTP.object(data)
            if account.provider == .googleDrive { try GoogleFileAccess.validateScope(json["scope"] as? String) }
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
        let timing = OperationLog.measure("file.remote_download"); defer { timing.end() }
        for attempt in 0...1 {
            var request = URLRequest(url: url); request.httpMethod = method
            for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
            request.setValue("Bearer \(try await token(account, forceRefresh: attempt == 1))", forHTTPHeaderField: "Authorization")
            let trace = OperationLog.isEnabled ? HTTPTaskTrace(operation: "cloud.download") : nil
            defer { trace?.finish() }
            let (temporary, response) = try await HTTP.session.download(for: request, delegate: trace)
            defer { try? FileManager.default.removeItem(at: temporary) }
            guard let http = response as? HTTPURLResponse else { throw BackupError.unsafe("다운로드 응답이 없습니다.") }
            if http.statusCode == 401 && attempt == 0 { continue }
            guard (200...299).contains(http.statusCode) else { throw HTTP.responseError(status: http.statusCode, url: url, data: (try? Data(contentsOf: temporary)) ?? Data()) }
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
