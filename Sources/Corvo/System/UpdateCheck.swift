import Foundation

/// Comparing two version strings.
///
/// Its own type, and tested, because the obvious way to do it is wrong in a way
/// that only shows up later: `"0.10.0" > "0.2.0"` is `false` as a string
/// comparison, so the tenth release of a series would be the one that stopped
/// telling anybody it existed.
enum AppVersion {
    /// What this bundle was built as. `Info.plist` rather than a constant in the
    /// source, so there is one place the version is set — `project.yml` — and no
    /// second copy to forget.
    static var current: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "0.0.0"
    }

    /// Component by component, numerically. A leading `v` is accepted because
    /// that is how the tags are written and the API hands them back that way.
    ///
    /// Anything that does not parse answers `false` rather than guessing. The
    /// cost of being wrong here is asymmetric: a missed update is a user on an
    /// old version, while a phantom one is the app claiming a release that does
    /// not exist, every launch, with nothing to install.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let new = numbers(in: candidate), let old = numbers(in: current) else {
            return false
        }
        for index in 0..<max(new.count, old.count) {
            let left = index < new.count ? new[index] : 0
            let right = index < old.count ? old[index] : 0
            guard left == right else { return left > right }
        }
        return false
    }

    /// `nil` when any component is not a plain number, which also rules out
    /// pre-release suffixes like `0.3.0-rc1`. GitHub's `releases/latest` skips
    /// pre-releases and drafts on its own, so this is the second of two guards
    /// rather than the only one.
    private static func numbers(in version: String) -> [Int]? {
        var text = Substring(version)
        if text.first == "v" || text.first == "V" { text = text.dropFirst() }
        guard !text.isEmpty else { return nil }

        var out: [Int] = []
        for part in text.split(separator: ".", omittingEmptySubsequences: false) {
            guard let number = Int(part), number >= 0 else { return nil }
            out.append(number)
        }
        return out
    }
}

/// Asks GitHub what the newest release is.
///
/// This is the only thing in Corvo that opens a network connection, which is why
/// it is one small type with one URL in it rather than a client: it sends no
/// clipping, no identifier and no query — a plain GET at a fixed path — and the
/// README says so in the two places that promise the app stays off the network.
///
/// It does not download or install anything. An ad-hoc signed app has no stable
/// code identity, so replacing its own bundle would drop the Accessibility
/// permission it needs to paste, silently, every time it updated. Until there is
/// a Developer ID to sign with, the honest thing this can do is say a release
/// exists and let Homebrew or the user install it.
enum UpdateCheck {
    struct Release: Equatable, Sendable {
        let version: String
        let url: URL
    }

    /// `releases/latest`, not `releases`: it excludes drafts and pre-releases,
    /// so a tag pushed to try something does not announce itself to everyone.
    static let endpoint = URL(string:
        "https://api.github.com/repos/Wylp/Corvo/releases/latest")!

    private struct Payload: Decodable {
        let tagName: String
        let htmlURL: String

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }
    }

    static func latest(session: URLSession = .shared) async throws -> Release {
        var request = URLRequest(url: endpoint, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // The REST API asks for one, and a request without it can be refused.
        // The version is in it because that is what the server would learn from
        // the request anyway if it were an update *service*; nothing else is.
        request.setValue("Corvo/\(AppVersion.current)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard let url = URL(string: payload.htmlURL) else {
            throw URLError(.badServerResponse)
        }
        return Release(version: payload.tagName, url: url)
    }
}
