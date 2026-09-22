import CoordinatedCalendarCore
import Testing

private let home = "/Users/someone"
private func problem(_ path: String) -> InstallLocation.Problem? {
    InstallLocation.problem(forBundlePath: path, home: home)
}

@Test func anApplicationsFolderIsFine() {
    #expect(problem("/Users/someone/Applications/CoordinatedCalendar.app") == nil)
    #expect(problem("/Applications/CoordinatedCalendar.app") == nil)
    #expect(problem("/Applications/Utilities/CoordinatedCalendar.app") == nil)
}

@Test func openedStraightFromTheDownloadIsNamedAsSuch() {
    // Where macOS actually runs a quarantined app that was not moved first.
    #expect(problem("/private/var/folders/xy/abc123/T/AppTranslocation/6F1E2C3D-0000/d/CoordinatedCalendar.app") == .translocated)
}

@Test func theDiskImageIsRefused() {
    #expect(problem("/Volumes/CoordinatedCalendar/CoordinatedCalendar.app") == .diskImage)
}

@Test func temporaryFoldersAreRefused() {
    #expect(problem("/private/tmp/build/CoordinatedCalendar.app") == .temporaryFolder)
    #expect(problem("/tmp/CoordinatedCalendar.app") == .temporaryFolder)
    #expect(problem("/private/var/folders/xy/abc123/T/CoordinatedCalendar.app") == .temporaryFolder)
}

@Test func anywhereElseIsRefusedBecauseItBreaksWhenMoved() {
    #expect(problem("/Users/someone/Downloads/CoordinatedCalendar.app") == .outsideApplications)
    #expect(problem("/Users/someone/Desktop/CoordinatedCalendar.app") == .outsideApplications)
    // A folder whose name merely starts with "Applications" is not the Applications folder.
    #expect(problem("/Users/someone/ApplicationsOld/CoordinatedCalendar.app") == .outsideApplications)
    #expect(problem("/ApplicationsBackup/CoordinatedCalendar.app") == .outsideApplications)
}
