import Foundation

nonisolated enum LinkError: LocalizedError, Equatable {
    case invalidURL
    case notALink
    case browserUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "This link is not a complete address. Use one that starts with http:// or https://."
        case .notALink:
            "There is no link to paste. Copy an address that starts with http:// or https://."
        case .browserUnavailable: "The default browser could not open this link. Try again."
        }
    }
}

nonisolated enum WebLink {
    // A complete HTTP or HTTPS URL with a host, or nil.
    static func url(from text: String) -> URL? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil,
            let url = URL(string: text, encodingInvalidCharacters: false),
            let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
            let host = url.host(), !host.isEmpty
        else { return nil }
        return url
    }

    // Reads pasted text as a link. Text that looks like an address but is not a complete one is
    // an invalid link. Other text is not a link at all.
    static func parse(_ text: String) throws -> URL {
        if let url = url(from: text) { return url }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.contains("://") || text.hasPrefix("www.") { throw LinkError.invalidURL }
        throw LinkError.notALink
    }

    // The title a new link gets: its host without "www.".
    static func title(for url: URL) -> String {
        let host = url.host() ?? url.absoluteString
        if host.lowercased().hasPrefix("www."), host.count > 4 { return String(host.dropFirst(4)) }
        return host
    }
}
