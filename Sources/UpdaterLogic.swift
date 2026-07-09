import Foundation

/// Pure logic for the self-updater (release parsing, version comparison).
/// No networking, no filesystem — unit-tested headlessly by `./build.sh --test`.
enum UpdaterLogic {
    struct Release: Equatable {
        let version: String   // "0.3.0" (tag with the leading v stripped)
        let zipURL: String    // browser_download_url of Squat-Coach-<version>.zip
        let pageURL: String   // html_url of the release, for manual fallback
    }

    static func isNewer(latest: String, current: String) -> Bool {
        latest.compare(current, options: .numeric) == .orderedDescending
    }

    /// Defense-in-depth: only ever download update zips from GitHub's own
    /// hosts, whatever URL the release JSON claims.
    static func isTrustedDownloadURL(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host else { return false }
        return host == "github.com" || host.hasSuffix(".githubusercontent.com")
    }

    /// Parse the GitHub releases/latest JSON. Returns nil when the payload is
    /// malformed or the release has no correctly-named zip asset — callers fall
    /// back to opening the releases page rather than guessing at a download.
    static func parseRelease(_ data: Data) -> Release? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let page = obj["html_url"] as? String
            ?? "https://github.com/brianyoungilcho/squat-coach/releases"
        let zipName = "Squat-Coach-\(version).zip"
        let assets = obj["assets"] as? [[String: Any]] ?? []
        guard let zip = assets.first(where: { ($0["name"] as? String) == zipName })?["browser_download_url"] as? String
        else { return nil }
        return Release(version: version, zipURL: zip, pageURL: page)
    }
}
