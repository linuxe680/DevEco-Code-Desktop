import Foundation

/// Converts framework/transport errors into text that is safe to show in the
/// app banner. `error.localizedDescription` can surface raw NSCocoa strings
/// (e.g. "未能读取数据，因为它的格式不正确。") when a URL cache or plist is
/// malformed; those messages are not actionable and look like an app bug.
enum UserFacingError {
    /// Last line of defence for text that reached the UI through a path that
    /// did not call `message(_:)`. Some framework errors are rendered locally
    /// as this generic Cocoa string; it is never actionable in our UI.
    static func sanitize(_ text: String) -> String {
        if text.localizedCaseInsensitiveContains("未能读取数据")
            || text.localizedCaseInsensitiveContains("格式不正确")
            || text.localizedCaseInsensitiveContains("格式错误")
            || text.localizedCaseInsensitiveContains("读取数据时出错")
            || text.localizedCaseInsensitiveContains("couldn't be read")
            || text.localizedCaseInsensitiveContains("couldn’t be read")
            || text.localizedCaseInsensitiveContains("could not be read")
            || text.localizedCaseInsensitiveContains("was not read")
            || text.localizedCaseInsensitiveContains("format is incorrect")
            || text.localizedCaseInsensitiveContains("correct format") {
            return NSLocalizedString(
                "Stored data could not be read. The app will rebuild it automatically.",
                comment: "Friendly replacement for NSCocoa file-format errors"
            )
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only a *bare* transport error (e.g. "Could not connect to the
        // server.") is worth replacing. Structured errors such as
        // "Server returned 500: connection refused by provider" carry the
        // real diagnosis and must survive verbatim — routing every string
        // that happens to contain "connection" through FailureKind hid
        // server-side failures behind a misleading network message.
        if isBareTransportError(trimmed) {
            return NSLocalizedString(
                "Could not reach the deveco server. Check the connection and retry.",
                comment: "Friendly network error"
            )
        }
        return trimmed
    }

    /// Recognises the short, unadorned shape of URLSession transport errors.
    /// A colon (ASCII or fullwidth) signals "label: detail" — somebody else's
    /// actionable message — so those are never treated as bare transport text.
    static func isBareTransportError(_ text: String) -> Bool {
        guard text.count <= 120,
              !text.contains(":"), !text.contains("：") else { return false }
        let lower = text.lowercased()
        return bareTransportPrefixes.contains { lower.hasPrefix($0) }
    }

    private static let bareTransportPrefixes = [
        "could not connect", "couldn't connect", "cannot connect", "can't connect",
        "the internet connection", "connection lost", "connection refused",
        "network connection", "a server with the specified hostname",
        "the request timed out", "request timed out", "timed out",
    ]

    static func message(_ error: Error) -> String {
        if let apiError = error as? APIError {
            return sanitize(apiError.localizedDescription)
        }
        let nsError = error as NSError
        switch (nsError.domain, nsError.code) {
        case (NSCocoaErrorDomain, 260), (NSCocoaErrorDomain, 261):
            return NSLocalizedString(
                "Stored data could not be read. The app will rebuild it automatically.",
                comment: "Friendly replacement for NSCocoa file-format errors"
            )
        case (NSURLErrorDomain, _):
            return NSLocalizedString(
                "Could not reach the deveco server. Check the connection and retry.",
                comment: "Friendly network error"
            )
        default:
            let raw = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            if raw.isEmpty {
                return FailureKind.classify(raw).label
            }
            return raw
        }
    }
}
