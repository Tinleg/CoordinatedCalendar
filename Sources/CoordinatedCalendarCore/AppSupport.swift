import Foundation

/// The app's folder under ~/Library/Application Support.
public enum AppSupport {
    public static let folderName = "CoordinatedCalendar"

    /// The folder, created if needed.
    public static func directory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = base.appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
