import CoordinatedCalendarCore
import Foundation

/// Asks GitHub for the latest published release. This is the only network request the app makes, and only
/// when the person clicks Check for Updates, or once a week when the app is opened, unless they turn that off. It sends nothing about their
/// calendars: the request is the public "latest release" address, and the answer is a version number.
enum UpdateChecker {
    static let latestReleaseURL = URL(string: "https://api.github.com/repos/Tinleg/CoordinatedCalendar/releases/latest")!
    static let releasesPage = URL(string: "https://github.com/Tinleg/CoordinatedCalendar/releases")!
    private static let automaticKey = "checkForUpdatesAutomatically"
    private static let lastCheckKey = "lastUpdateCheck"
    private static let week: TimeInterval = 7 * 24 * 60 * 60

    enum Outcome: Equatable {
        case upToDate(version: String)
        case available(version: String, page: URL)
        case failed(reason: String)
    }

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// On unless the person turns it off, so people hear about fixes without having to go looking.
    static var checksAutomatically: Bool {
        get { UserDefaults.standard.object(forKey: automaticKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: automaticKey) }
    }

    static var isDueForAutomaticCheck: Bool {
        guard checksAutomatically else { return false }
        guard let last = UserDefaults.standard.object(forKey: lastCheckKey) as? Date else { return true }
        return Date().timeIntervalSince(last) >= week
    }

    static func check() async -> Outcome {
        var request = URLRequest(url: latestReleaseURL, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("CoordinatedCalendar/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                return .failed(reason: "GitHub answered with status \(status). Try again later, or look at \(releasesPage.absoluteString).")
            }
            struct Release: Decodable {
                let tag_name: String
                let html_url: URL
            }
            let release = try JSONDecoder().decode(Release.self, from: data)
            UserDefaults.standard.set(Date(), forKey: lastCheckKey)
            guard let latest = ReleaseVersion(release.tag_name), let current = ReleaseVersion(currentVersion) else {
                return .failed(reason: "Could not read the release version \"\(release.tag_name)\".")
            }
            return latest > current
                ? .available(version: latest.description, page: release.html_url)
                : .upToDate(version: current.description)
        } catch {
            return .failed(reason: error.localizedDescription)
        }
    }
}
