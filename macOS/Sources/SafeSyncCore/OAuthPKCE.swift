import Foundation
import CryptoKit
import Security

public struct OAuthPKCE: Sendable {
    public let verifier: String
    public let challenge: String
    public let state: String
    public init() throws {
        var bytes = [UInt8](repeating: 0, count: 64)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw BackupError.unsafe("보안 난수를 만들 수 없습니다.") }
        verifier = Self.base64(Data(bytes.prefix(32)))
        state = Self.base64(Data(bytes.suffix(32)))
        challenge = Self.base64(Data(SHA256.hash(data: Data(verifier.utf8))))
    }
    public static func base64(_ data: Data) -> String { data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    public static func authorizationURL(account: CloudAccount, redirect: String, pkce: OAuthPKCE) -> URL {
        var query = ["client_id": account.clientID, "response_type": "code", "redirect_uri": redirect, "state": pkce.state, "code_challenge": pkce.challenge, "code_challenge_method": "S256"]
        if account.provider == .dropbox { query["token_access_type"] = "offline" }
        else { query["scope"] = "https://www.googleapis.com/auth/drive"; query["access_type"] = "offline"; query["prompt"] = "consent" }
        return HTTP.url(account.provider == .dropbox ? "https://www.dropbox.com/oauth2/authorize" : "https://accounts.google.com/o/oauth2/v2/auth", query: query)
    }
    public static func exchange(account: CloudAccount, code: String, redirect: String, verifier: String, clientSecret: String) async throws -> CloudSecret {
        var params = ["client_id": account.clientID, "grant_type": "authorization_code", "code": code, "redirect_uri": redirect, "code_verifier": verifier]
        if account.provider == .googleDrive && !clientSecret.isEmpty { params["client_secret"] = clientSecret }
        var request = URLRequest(url: URL(string: account.provider == .dropbox ? "https://api.dropboxapi.com/oauth2/token" : "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"; request.httpBody = HTTP.form(params); request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let (data, _) = try await HTTP.send(request); let json = try HTTP.object(data)
        guard let access = json["access_token"] as? String, let refresh = json["refresh_token"] as? String else { throw BackupError.unsafe("장기 인증 토큰이 없습니다. 계정 접근 동의를 확인하고 다시 연결하세요.") }
        return CloudSecret(accessToken: access, refreshToken: refresh, clientSecret: clientSecret, expiresAt: Date().addingTimeInterval((json["expires_in"] as? Double) ?? 3600))
    }
}
