import CoordinatedCalendarCore
import Darwin
import EventKit
import Foundation

@MainActor
final class BridgeViewModel: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case singleCopy = "Single Copy"
        case consolidatedSync = "Consolidated Sync"

        var id: String { rawValue }
    }

    @Published var calendars: [CalendarIdentity] = []
    @Published var settings = BridgeSettings()
    @Published var mode: Mode = .singleCopy
    @Published var consolidatedCalendarKey: String?
    @Published var contributorCalendarKeys: Set<String> = []
    @Published var recipientCalendarKeys: Set<String> = []
    @Published var contributorIntervals: [String: Int] = [:]
    @Published var recipientIntervals: [String: Int] = [:]
    @Published var contributorAvailabilities: [String: DestinationAvailability] = [:]
    @Published var recipientAvailabilities: [String: DestinationAvailability] = [:]
    @Published var fanOutTitle = FreeBusyCompliance.fanOutTitle
    @Published var skipFreeEvents = true
    @Published var skipDeclinedEvents = true
    @Published var syncInterval = 300
    @Published var lastSync: SyncRunStatus?
    @Published var backgroundJobsInstalled = false
    @Published var backgroundJobs: [SyncAgentInstaller.JobDetails] = []
    /// Set when the settings folder could not be opened; changes are disabled until the app is relaunched.
    @Published var startupError: String?
    /// `-demoMode YES` shows synthetic calendars for screenshots and never reads or writes calendars or settings.
    let isDemo = UserDefaults.standard.bool(forKey: "demoMode")
    @Published var result = SyncResult()
    @Published var statusText = "Calendar access has not been checked."
    @Published var progress = 0.0
    @Published var isRunning = false
    @Published var permissionStatus: EKAuthorizationStatus = .notDetermined

    private let engine: CoordinatedCalendarEngine
    private let guiSettingsStore: GUISettingsStore
    private var task: Task<Void, Never>?

    init() {
        if isDemo {
            engine = CoordinatedCalendarEngine(ledger: MappingLedger.inMemory())
            guiSettingsStore = GUISettingsStore.inMemory()
            loadDemoData()
            return
        }
        do {
            let ledger = try MappingLedger()
            let store = try GUISettingsStore()
            engine = CoordinatedCalendarEngine(ledger: ledger)
            guiSettingsStore = store
        } catch {
            // Keep the app usable for reading what's wrong instead of crashing; nothing is saved.
            engine = CoordinatedCalendarEngine(ledger: MappingLedger.inMemory())
            guiSettingsStore = GUISettingsStore.inMemory()
            startupError = "CoordinatedCalendar couldn't open its settings folder (~/Library/Application Support/\(AppSupport.folderName)): \(error.localizedDescription). Fix the folder's permissions, then relaunch. Syncing and changes are disabled until then."
            statusText = "Settings folder unavailable."
            return
        }
        restoreGUISettings()
        refreshSyncStatus()
        permissionStatus = engine.authorizationStatus()
        if permissionStatus == .fullAccess {
            refreshCalendars()
            statusText = "Ready."
        }
    }

    /// Actions that read or write calendars, settings or LaunchAgents are blocked in demo mode and when the
    /// settings folder is unavailable.
    private var actionsBlocked: Bool {
        if isDemo {
            statusText = "Demo mode: nothing is read or written."
            return true
        }
        if startupError != nil {
            statusText = "Settings folder unavailable; relaunch after fixing it."
            return true
        }
        return false
    }

    func requestAccess() {
        guard !actionsBlocked else { return }
        task?.cancel()
        task = Task {
            do {
                let granted = try await engine.requestAccess()
                permissionStatus = engine.authorizationStatus()
                statusText = granted ? "Calendar full access granted." : "Calendar access was denied."
                refreshCalendars()
            } catch {
                statusText = error.localizedDescription
            }
        }
    }

    func refreshCalendars() {
        guard !isDemo else { return }
        calendars = engine.calendars()
        if settings.sourceCalendarKey == nil {
            settings.sourceCalendarKey = calendars.first?.stableKey
        }
        if settings.destinationCalendarKey == nil {
            settings.destinationCalendarKey = calendars.first(where: \.allowsContentModifications)?.stableKey
        }
        if consolidatedCalendarKey == nil {
            consolidatedCalendarKey = calendars.first {
                $0.displayName.localizedCaseInsensitiveContains("consolidated")
            }?.stableKey
        }
        pruneAutomationSelections()
    }

    func preview() {
        guard !actionsBlocked else { return }
        run(dryRun: true)
    }

    func copyEvents() {
        guard !actionsBlocked else { return }
        run(dryRun: false)
    }

    func previewConsolidatedSync() {
        guard !actionsBlocked else { return }
        runConsolidatedSync(dryRun: true)
    }

    func executeConsolidatedSync() {
        guard !actionsBlocked else { return }
        runConsolidatedSync(dryRun: false)
    }

    func previewRemoveEverything() {
        guard !actionsBlocked else { return }
        runRemoval(dryRun: true)
    }

    /// Uninstall step: removes the background jobs first, so a scheduled sync can't recreate anything, then
    /// every event this app created, in every calendar.
    func removeEverything() {
        guard !actionsBlocked else { return }
        do {
            try SyncAgentInstaller.removeAll()
            refreshSyncStatus()
        } catch {
            result = failureResult("Could not remove the background jobs, so nothing was deleted: \(error.localizedDescription)")
            return
        }
        runRemoval(dryRun: false)
    }

    private func runRemoval(dryRun: Bool) {
        task?.cancel()
        isRunning = true
        result = SyncResult()
        progress = 0
        statusText = dryRun ? "Finding everything CoordinatedCalendar created..." : "Removing everything CoordinatedCalendar created..."
        let window = CoordinatedCalendarEngine.removalWindow()

        task = Task { [self] in
            let removal = await engine.removeAllCopies(from: window.start, to: window.end, dryRun: dryRun) { [weak self] progress, title in
                Task { @MainActor in
                    self?.progress = progress
                    self?.statusText = "Checking \(title)"
                }
            }
            result = removal
            isRunning = false
            progress = 1
            statusText = dryRun
                ? "Preview: \(removal.deleted) events CoordinatedCalendar created would be removed. Nothing has changed."
                : "Removed \(removal.deleted) events CoordinatedCalendar created; \(removal.failed) failed. Background jobs are removed."
        }
    }

    func setConsolidatedCalendar(_ key: String?) {
        consolidatedCalendarKey = key
        if let key {
            contributorCalendarKeys.remove(key)
            recipientCalendarKeys.remove(key)
        }
        normalizeContributorAvailabilities()
        saveGUISettings()
    }

    func setContributor(_ key: String, enabled: Bool) {
        guard key != consolidatedCalendarKey else { return }
        if enabled {
            contributorCalendarKeys.insert(key)
            contributorIntervals[key, default: 300] = contributorIntervals[key] ?? 300
            contributorAvailabilities[key, default: .busy] = contributorAvailabilities[key] ?? .busy
        } else {
            contributorCalendarKeys.remove(key)
        }
        saveGUISettings()
    }

    func setRecipient(_ key: String, enabled: Bool) {
        guard key != consolidatedCalendarKey else { return }
        if enabled {
            recipientCalendarKeys.insert(key)
            recipientIntervals[key, default: 300] = recipientIntervals[key] ?? 300
            recipientAvailabilities[key, default: .busy] = recipientAvailabilities[key] ?? .busy
        } else {
            recipientCalendarKeys.remove(key)
        }
        saveGUISettings()
    }

    func contributorInterval(for key: String) -> Int {
        contributorIntervals[key] ?? 300
    }

    func contributorAvailability(for key: String) -> DestinationAvailability {
        let availability = contributorAvailabilities[key] ?? .busy
        return contributorAvailabilityOptions(for: key).contains(availability) ? availability : .preserve
    }

    func contributorAvailabilityOptions(for _: String) -> [DestinationAvailability] {
        DestinationAvailability.allCases
    }

    func recipientAvailability(for key: String) -> DestinationAvailability {
        let availability = recipientAvailabilities[key] ?? .busy
        return recipientAvailabilityOptions(for: key).contains(availability) ? availability : .preserve
    }

    func recipientAvailabilityOptions(for key: String) -> [DestinationAvailability] {
        guard let recipient = calendars.first(where: { $0.stableKey == key }) else {
            return DestinationAvailability.allCases
        }

        var options: [DestinationAvailability] = [.preserve]
        let supported = Set(recipient.supportedAvailabilities)
        if supported.contains("free") {
            options.append(.free)
        }
        if supported.contains("busy") {
            options.append(.busy)
        }
        if supported.contains("tentative") {
            options.append(.tentative)
        }
        return options
    }

    func recipientInterval(for key: String) -> Int {
        recipientIntervals[key] ?? 300
    }

    func setContributorInterval(_ interval: Int, for key: String) {
        contributorIntervals[key] = interval
        saveGUISettings()
    }

    func setContributorAvailability(_ availability: DestinationAvailability, for key: String) {
        contributorAvailabilities[key] = contributorAvailabilityOptions(for: key).contains(availability) ? availability : .preserve
        saveGUISettings()
    }

    func setRecipientAvailability(_ availability: DestinationAvailability, for key: String) {
        recipientAvailabilities[key] = recipientAvailabilityOptions(for: key).contains(availability) ? availability : .preserve
        saveGUISettings()
    }

    func setRecipientInterval(_ interval: Int, for key: String) {
        recipientIntervals[key] = interval
        saveGUISettings()
    }

    func submitBackgroundJobs() {
        guard !actionsBlocked else { return }
        guard consolidatedCalendarKey != nil else {
            result = failureResult("Choose a consolidated calendar before submitting background jobs.")
            return
        }
        guard !contributorCalendarKeys.isEmpty || !recipientCalendarKeys.isEmpty else {
            result = failureResult("Choose at least one contributor or recipient calendar.")
            return
        }

        do {
            // One job runs every fan-in, then every fan-out, from the saved settings.
            saveGUISettings()
            try SyncAgentInstaller.install(
                interval: syncInterval,
                windowArguments: SyncAgentInstaller.relativeWindowArguments(start: settings.startDate, end: settings.endDate)
            )
            refreshSyncStatus()
            statusText = "Submitted the CoordinatedCalendar sync job and health check."
        } catch {
            result = failureResult(error.localizedDescription)
        }
    }

    func removeBackgroundJobs() {
        guard !actionsBlocked else { return }
        do {
            let removed = try SyncAgentInstaller.removeAll()
            refreshSyncStatus()
            statusText = "Removed \(removed) CoordinatedCalendar background job\(removed == 1 ? "" : "s")."
        } catch {
            result = failureResult(error.localizedDescription)
        }
    }

    func setFanOutTitle(_ title: String) {
        fanOutTitle = title
        saveGUISettings()
    }

    func setSkipFreeEvents(_ skip: Bool) {
        skipFreeEvents = skip
        saveGUISettings()
    }

    func setSkipDeclinedEvents(_ skip: Bool) {
        skipDeclinedEvents = skip
        saveGUISettings()
    }

    func setSyncInterval(_ interval: Int) {
        syncInterval = interval
        saveGUISettings()
    }

    /// Reloads the last scheduled sync result and whether the background jobs are installed.
    func refreshSyncStatus() {
        guard !isDemo else { return }
        lastSync = SyncStatusStore.load()
        backgroundJobsInstalled = SyncAgentInstaller.isInstalled
        backgroundJobs = SyncAgentInstaller.installedJobs()
    }

    func cancel() {
        task?.cancel()
        isRunning = false
        statusText = "Cancelled."
    }

    private func run(dryRun: Bool) {
        task?.cancel()
        isRunning = true
        result = SyncResult()
        progress = 0
        statusText = dryRun ? "Preparing preview..." : "Copying events..."

        var runSettings = settings
        runSettings.dryRun = dryRun

        task = Task { [self] in
            let syncResult = await engine.run(settings: runSettings) { [weak self] progress, title in
                Task { @MainActor in
                    self?.progress = progress
                    self?.statusText = title
                }
            }
            result = syncResult
            isRunning = false
            progress = 1
            statusText = "\(dryRun ? "Preview" : "Copy") finished: \(syncResult.created) create, \(syncResult.skipped) skipped, \(syncResult.updated) updated, \(syncResult.blocked) blocked, \(syncResult.failed) failed."
        }
    }

    private func runConsolidatedSync(dryRun: Bool) {
        task?.cancel()
        isRunning = true
        result = SyncResult()
        progress = 0
        statusText = dryRun ? "Preparing consolidated preview..." : "Running consolidated sync..."

        let consolidatedKey = consolidatedCalendarKey
        let contributorKeys = contributorCalendarKeys
        let recipientKeys = recipientCalendarKeys
        let plan = currentGUISettings()
        let startDate = settings.startDate
        let endDate = settings.endDate

        task = Task { [self] in
            guard let consolidatedKey else {
                result = failureResult("Choose a consolidated calendar.")
                isRunning = false
                progress = 1
                return
            }
            guard !contributorKeys.isEmpty else {
                result = failureResult("Choose at least one contributing calendar.")
                isRunning = false
                progress = 1
                return
            }
            guard !recipientKeys.isEmpty else {
                result = failureResult("Choose at least one free/busy recipient calendar.")
                isRunning = false
                progress = 1
                return
            }

            var aggregate = SyncResult()
            let totalSteps = contributorKeys.count + recipientKeys.count
            var completedSteps = 0

            for sourceKey in contributorKeys.sorted() {
                if Task.isCancelled { break }
                let stepIndex = completedSteps
                let runSettings = plan.fanInSettings(
                    sourceKey: sourceKey,
                    consolidatedKey: consolidatedKey,
                    startDate: startDate,
                    endDate: endDate,
                    dryRun: dryRun
                )

                let syncResult = await engine.run(settings: runSettings) { [weak self] stepProgress, title in
                    Task { @MainActor in
                        self?.progress = (Double(stepIndex) + stepProgress) / Double(max(totalSteps, 1))
                        self?.statusText = "Fan-in: \(title)"
                    }
                }
                aggregate.merge(syncResult)
                completedSteps += 1
            }

            for destinationKey in recipientKeys.sorted() {
                if Task.isCancelled { break }
                let stepIndex = completedSteps
                let runSettings = plan.fanOutSettings(
                    consolidatedKey: consolidatedKey,
                    destinationKey: destinationKey,
                    availability: recipientAvailability(for: destinationKey),
                    startDate: startDate,
                    endDate: endDate,
                    dryRun: dryRun
                )

                let syncResult = await engine.run(settings: runSettings) { [weak self] stepProgress, title in
                    Task { @MainActor in
                        self?.progress = (Double(stepIndex) + stepProgress) / Double(max(totalSteps, 1))
                        self?.statusText = "Fan-out: \(title)"
                    }
                }
                aggregate.merge(syncResult)
                completedSteps += 1
            }

            result = aggregate
            isRunning = false
            progress = 1
            refreshSyncStatus()
            statusText = "\(dryRun ? "Preview" : "Sync") finished: \(aggregate.created) create, \(aggregate.updated) updated, \(aggregate.skipped) skipped, \(aggregate.blocked) blocked, \(aggregate.failed) failed."
        }
    }

    private func pruneAutomationSelections() {
        let keys = Set(calendars.map(\.stableKey))
        contributorCalendarKeys.formIntersection(keys)
        recipientCalendarKeys.formIntersection(keys)
        contributorIntervals = contributorIntervals.filter { keys.contains($0.key) }
        recipientIntervals = recipientIntervals.filter { keys.contains($0.key) }
        contributorAvailabilities = contributorAvailabilities.filter { keys.contains($0.key) }
        recipientAvailabilities = recipientAvailabilities.filter { keys.contains($0.key) }
        if let consolidatedCalendarKey, !keys.contains(consolidatedCalendarKey) {
            self.consolidatedCalendarKey = nil
        }
        normalizeContributorAvailabilities()
        normalizeRecipientAvailabilities()
        if let consolidatedCalendarKey {
            contributorCalendarKeys.remove(consolidatedCalendarKey)
            recipientCalendarKeys.remove(consolidatedCalendarKey)
        }
        saveGUISettings()
    }

    func setMode(_ mode: Mode) {
        self.mode = mode
        saveGUISettings()
    }

    func updateSettings<Value>(_ keyPath: WritableKeyPath<BridgeSettings, Value>, to value: Value) {
        settings[keyPath: keyPath] = value
        saveGUISettings()
    }

    private func restoreGUISettings() {
        do {
            guard let stored = try guiSettingsStore.load() else {
                return
            }
            if let storedMode = Mode(rawValue: stored.modeRawValue) {
                mode = storedMode
            }
            if let startDate = stored.startDate {
                settings.startDate = startDate
            }
            if let endDate = stored.endDate {
                settings.endDate = endDate
            }
            consolidatedCalendarKey = stored.consolidatedCalendarKey
            contributorCalendarKeys = Set(stored.contributorCalendarKeys)
            recipientCalendarKeys = Set(stored.recipientCalendarKeys)
            contributorIntervals = stored.contributorIntervals
            recipientIntervals = stored.recipientIntervals
            contributorAvailabilities = stored.contributorAvailabilities ?? [:]
            recipientAvailabilities = stored.recipientAvailabilities ?? [:]
            fanOutTitle = stored.effectiveFanOutTitle
            skipFreeEvents = stored.skipFreeEvents ?? true
            skipDeclinedEvents = stored.skipDeclinedEvents ?? true
            syncInterval = stored.effectiveSyncInterval
            normalizeContributorAvailabilities()
            normalizeRecipientAvailabilities()
        } catch {
            statusText = "Could not load saved GUI settings: \(error.localizedDescription)"
        }
    }

    private func normalizeContributorAvailabilities() {
        let options = DestinationAvailability.allCases
        for key in Array(contributorAvailabilities.keys) where !options.contains(contributorAvailabilities[key] ?? .busy) {
            contributorAvailabilities[key] = options.contains(.busy) ? .busy : .preserve
        }
    }

    private func normalizeRecipientAvailabilities() {
        for key in Array(recipientAvailabilities.keys) {
            let options = recipientAvailabilityOptions(for: key)
            if !options.contains(recipientAvailabilities[key] ?? .busy) {
                recipientAvailabilities[key] = options.contains(.busy) ? .busy : .preserve
            }
        }
    }

    private func saveGUISettings() {
        guard !isDemo, startupError == nil else { return }
        do {
            try guiSettingsStore.save(currentGUISettings())
        } catch {
            statusText = "Could not save GUI settings: \(error.localizedDescription)"
        }
    }

    private func currentGUISettings() -> GUISettings {
        GUISettings(
            modeRawValue: mode.rawValue,
            startDate: self.settings.startDate,
            endDate: self.settings.endDate,
            consolidatedCalendarKey: consolidatedCalendarKey,
            contributorCalendarKeys: contributorCalendarKeys.sorted(),
            recipientCalendarKeys: recipientCalendarKeys.sorted(),
            contributorIntervals: contributorIntervals,
            recipientIntervals: recipientIntervals,
            contributorAvailabilities: contributorAvailabilities,
            recipientAvailabilities: recipientAvailabilities,
            fanOutTitle: fanOutTitle,
            skipFreeEvents: skipFreeEvents,
            skipDeclinedEvents: skipDeclinedEvents,
            syncInterval: syncInterval
        )
    }

    private func loadDemoData() {
        let calendars = [
            CalendarIdentity(sourceIdentifier: "demo-icloud", sourceTitle: "iCloud", sourceType: "calDAV", calendarIdentifier: "consolidated", calendarTitle: "Consolidated", allowsContentModifications: true, supportedAvailabilities: ["free", "busy"]),
            CalendarIdentity(sourceIdentifier: "demo-icloud", sourceTitle: "iCloud", sourceType: "calDAV", calendarIdentifier: "personal", calendarTitle: "Personal", allowsContentModifications: true, supportedAvailabilities: ["free", "busy"]),
            CalendarIdentity(sourceIdentifier: "demo-work", sourceTitle: "Work", sourceType: "exchange", calendarIdentifier: "calendar", calendarTitle: "Calendar", allowsContentModifications: true, supportedAvailabilities: ["free", "busy", "tentative", "unavailable"]),
            CalendarIdentity(sourceIdentifier: "demo-client", sourceTitle: "Client", sourceType: "exchange", calendarIdentifier: "calendar", calendarTitle: "Calendar", allowsContentModifications: true, supportedAvailabilities: ["free", "busy", "tentative", "unavailable"]),
            CalendarIdentity(sourceIdentifier: "demo-other", sourceTitle: "Other", sourceType: "birthdays", calendarIdentifier: "birthdays", calendarTitle: "Birthdays", allowsContentModifications: false),
            CalendarIdentity(sourceIdentifier: "demo-subscribed", sourceTitle: "Subscribed Calendars", sourceType: "subscribed", calendarIdentifier: "holidays", calendarTitle: "US Holidays", allowsContentModifications: false)
        ]
        self.calendars = calendars
        let key = { (source: String, calendar: String) in "\(source)::\(calendar)" }
        consolidatedCalendarKey = key("demo-icloud", "consolidated")
        contributorCalendarKeys = [key("demo-icloud", "personal"), key("demo-work", "calendar"), key("demo-client", "calendar")]
        recipientCalendarKeys = contributorCalendarKeys
        recipientAvailabilities = [key("demo-work", "calendar"): .preserve, key("demo-client", "calendar"): .tentative, key("demo-icloud", "personal"): .preserve]
        permissionStatus = .fullAccess
        backgroundJobsInstalled = true
        let executable = "/Applications/CoordinatedCalendar.app/Contents/MacOS/CoordinatedCalendar"
        let logs = "~/Library/Logs/io.github.tinleg.coordinatedcalendar"
        backgroundJobs = [
            SyncAgentInstaller.JobDetails(label: "io.github.tinleg.coordinatedcalendar.sync", plistPath: "~/Library/LaunchAgents/io.github.tinleg.coordinatedcalendar.sync.plist", interval: 300, runsAtLoad: true, arguments: [executable, "--sync-gui-settings", "--execute", "--window-days-past", "730", "--window-days-future", "1490"], logPath: logs + ".sync.log", errorLogPath: logs + ".sync.err.log", state: "not running", runs: "42", lastExitCode: "0"),
            SyncAgentInstaller.JobDetails(label: "io.github.tinleg.coordinatedcalendar.health", plistPath: "~/Library/LaunchAgents/io.github.tinleg.coordinatedcalendar.health.plist", interval: 900, runsAtLoad: false, arguments: [executable, "--health-check", "--notify", "--max-age-minutes", "20"], logPath: logs + ".health.log", errorLogPath: logs + ".health.err.log", state: "not running", runs: "14", lastExitCode: "0")
        ]
        mode = .consolidatedSync

        var summary = SyncResult()
        summary.scanned = 812
        summary.created = 3
        summary.updated = 2
        lastSync = SyncRunStatus(finishedAt: Date().addingTimeInterval(-140), result: summary)

        let now = Calendar.current.startOfDay(for: Date())
        func at(_ days: Double, _ hour: Double) -> Date { now.addingTimeInterval(days * 86_400 + hour * 3_600) }
        var demo = SyncResult()
        demo.scanned = 812
        demo.created = 3
        demo.updated = 1
        demo.skipped = 806
        demo.previews = [
            SyncEventPreview(id: "1", sourceTitle: "Quarterly Review", destinationTitle: "Work / Calendar: Quarterly Review", startDate: at(1, 9), action: .create, message: "Will create a new copy", sourceCalendarName: "Work / Calendar", destinationCalendarName: "iCloud / Consolidated", sourceAvailability: "Busy", resultingAvailability: "Busy", transformationSummary: "Mode: full detail copy"),
            SyncEventPreview(id: "2", sourceTitle: "Work / Calendar: Quarterly Review", destinationTitle: "Busy - Other", startDate: at(1, 9), action: .create, message: "Will create a new copy", sourceCalendarName: "iCloud / Consolidated", destinationCalendarName: "Client / Calendar", sourceAvailability: "Busy", resultingAvailability: "Tentative", transformationSummary: "Mode: free/busy block only"),
            SyncEventPreview(id: "3", sourceTitle: "Work / Calendar: Quarterly Review", destinationTitle: "Busy - Other", startDate: at(1, 9), action: .create, message: "Will create a new copy", sourceCalendarName: "iCloud / Consolidated", destinationCalendarName: "iCloud / Personal", sourceAvailability: "Busy", resultingAvailability: "Busy", transformationSummary: "Mode: free/busy block only"),
            SyncEventPreview(id: "4", sourceTitle: "Design Sync", destinationTitle: "Client / Calendar: Design Sync", startDate: at(2, 14), action: .update, message: "Would update copy found from synced metadata", sourceCalendarName: "Client / Calendar", destinationCalendarName: "iCloud / Consolidated", sourceAvailability: "Tentative", resultingAvailability: "Busy", transformationSummary: "Mode: full detail copy"),
            SyncEventPreview(id: "5", sourceTitle: "Team Offsite", destinationTitle: nil, startDate: at(3, 0), action: .skipDuplicate, message: "Skipped: marked Free", sourceCalendarName: "iCloud / Consolidated", destinationCalendarName: "Work / Calendar")
        ]
        result = demo
        statusText = "Demo mode: sample calendars, nothing is read or written."
        progress = 1
    }

    @discardableResult
    private func failureResult(_ message: String) -> SyncResult {
        var failure = SyncResult()
        failure.failed = 1
        failure.previews.append(SyncEventPreview(
            id: UUID().uuidString,
            sourceTitle: "CoordinatedCalendar",
            destinationTitle: nil,
            startDate: Date(),
            action: .error,
            message: message
        ))
        statusText = message
        return failure
    }
}

private extension SyncResult {
    mutating func merge(_ other: SyncResult) {
        scanned += other.scanned
        created += other.created
        deleted += other.deleted
        skipped += other.skipped
        updated += other.updated
        blocked += other.blocked
        failed += other.failed
        previews.append(contentsOf: other.previews)
    }
}
