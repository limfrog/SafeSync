import Foundation

/// App registration for a public desktop client, separate from each user's Keychain tokens.
/// The release build extracts only the installed-app fields from the developer's OAuth JSON.
public struct DesktopCloudRegistration: Sendable {
    public let clientID: String
    public let clientSecret: String
    public var isAvailable: Bool { !clientID.isEmpty }

    public init(clientID: String, clientSecret: String = "") {
        self.clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.clientSecret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func load(provider: CloudProvider, bundle: Bundle = .main) -> Self {
        if provider == .dropbox { return Self(clientID: "08al8ot9uye36k9") }
        guard let url = bundle.url(forResource: "GoogleDesktopOAuth", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let values = try? PropertyListDecoder().decode(GoogleRegistration.self, from: data),
              values.clientID.hasSuffix(".apps.googleusercontent.com"), !values.clientSecret.isEmpty
        else { return Self(clientID: "") }
        return Self(clientID: values.clientID, clientSecret: values.clientSecret)
    }
    private struct GoogleRegistration: Decodable {
        let clientID: String
        let clientSecret: String
    }
}
