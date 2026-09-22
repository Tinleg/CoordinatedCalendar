import Foundation

/// Where the app is running from, and whether background jobs can safely point at it. The jobs record
/// the app's path, so they break if that copy is moved, deleted, ejected or cleaned away.
public enum InstallLocation {
    public enum Problem: Equatable, Sendable {
        /// Opened straight from where it was downloaded: macOS runs a hidden, temporary copy instead.
        case translocated
        /// Running from a mounted disk image, which disappears when it is ejected.
        case diskImage
        /// A folder macOS clears, such as /tmp.
        case temporaryFolder
        /// Anywhere else — Downloads, Desktop — which works only until this copy is moved or deleted.
        case outsideApplications

        public var message: String {
            switch self {
            case .translocated:
                "macOS is running this copy of CoordinatedCalendar from a hidden temporary location, because it was opened straight from where it was downloaded. Quit, move CoordinatedCalendar to your Applications folder, and open it from there before turning on background syncing."
            case .diskImage:
                "CoordinatedCalendar is running from its disk image, which disappears when it is ejected. Drag it to your Applications folder and open it from there before turning on background syncing."
            case .temporaryFolder:
                "CoordinatedCalendar is running from a temporary folder that macOS clears. Move it to your Applications folder and open it from there before turning on background syncing."
            case .outsideApplications:
                "CoordinatedCalendar is not in an Applications folder. Background syncing would stop working if this copy were moved or deleted, so move it to Applications first and open it from there."
            }
        }
    }

    /// nil when the app is inside /Applications or ~/Applications, the only places background jobs may
    /// point at. `bundlePath` should already have symlinks resolved.
    public static func problem(forBundlePath bundlePath: String, home: String) -> Problem? {
        let path = (bundlePath as NSString).standardizingPath + "/"
        // Checked before the temporary folders, because a translocated copy also lives under /private/var/folders.
        if path.contains("/AppTranslocation/") { return .translocated }
        if path.hasPrefix("/Volumes/") { return .diskImage }
        if ["/private/tmp/", "/tmp/", "/private/var/folders/", "/var/folders/"].contains(where: path.hasPrefix) {
            return .temporaryFolder
        }
        let applications = ["/Applications/", (home as NSString).appendingPathComponent("Applications") + "/"]
        return applications.contains(where: path.hasPrefix) ? nil : .outsideApplications
    }
}
