import Foundation

/// Parses `needle://` URLs used by browsers and Shortcuts.
///
/// Supported forms:
/// - `needle://search?q=report`
/// - `needle://report`
/// - `needle://?query=report`
public enum DeepLink {
    /// Returns the search query encoded in a Needle URL, if any.
    public static func query(from url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }

        if let value = components.queryItems?.first(where: { item in
            ["q", "query", "s"].contains(item.name.lowercased())
        })?.value, !value.isEmpty {
            return value
        }

        if let host = url.host, !host.isEmpty, host.lowercased() != "search" {
            return host
        }
        return nil
    }
}
