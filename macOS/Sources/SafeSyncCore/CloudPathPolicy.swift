import Foundation

/// Provider-reserved OS metadata is out of scope, never evidence of a user deletion.
public enum CloudPathPolicy {
    private static let dropboxReserved = Set([".ds_store", "desktop.ini", "thumbs.db"])
    public static func isExcluded(_ path: String, provider: CloudProvider) -> Bool {
        provider == .dropbox && path.split(separator: "/").contains { dropboxReserved.contains($0.lowercased()) }
    }
}
