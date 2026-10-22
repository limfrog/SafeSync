import Foundation
import Darwin

public struct TransientNetworkFailure: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
public enum NetworkFailurePolicy {
    public static func isTransient(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if error is TransientNetworkFailure { return true }
        if let api = error as? APIError { return [408, 429, 500, 502, 503, 504].contains(api.status) }
        let value = error as NSError
        if value.domain == NSURLErrorDomain {
            return [URLError.timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .dnsLookupFailed, .notConnectedToInternet, .internationalRoamingOff, .callIsActive, .dataNotAllowed].contains { $0.rawValue == value.code }
        }
        if value.domain == NSPOSIXErrorDomain, [ETIMEDOUT, ENETDOWN, ENETRESET, ENETUNREACH, ECONNABORTED, ECONNRESET, EHOSTDOWN, EHOSTUNREACH, ECONNREFUSED, ENOTCONN].contains(Int32(value.code)) { return true }
        if let underlying = value.userInfo[NSUnderlyingErrorKey] as? Error { return isTransient(underlying) }
        return false
    }
    public static func legacyMessage(_ text: String) -> Bool {
        [408,429,500,502,503,504].contains { text.hasPrefix("클라우드 요청 실패 (\($0)):") }
    }
}
