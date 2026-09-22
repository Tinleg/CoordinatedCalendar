import CoordinatedCalendarCore
import EventKit
import AppKit
import SwiftUI

struct ContentView: View {
    private enum MessageSort: String, CaseIterable, Identifiable {
        case original = "Original"
        case ascending = "Message A-Z"
        case descending = "Message Z-A"

        var id: String { rawValue }
    }

    @ObservedObject var viewModel: BridgeViewModel
    @State private var selectedPreviewID: SyncEventPreview.ID?
    @State private var showingRemoveEverythingConfirmation = false
    @State private var messageFilter = ""
    @State private var messageSort: MessageSort = .original
    @State private var onlyShowNewAndChanged = false
    @State private var hideBridgeCreatedSkips = false

    enum Page: String, CaseIterable, Identifiable {
        case status = "Status"
        case calendars = "Calendars"
        case schedule = "Schedule"
        case run = "Preview & Run"
        case manualCopy = "Manual Copy"

        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .status: "heart.text.square"
            case .calendars: "point.3.connected.trianglepath.dotted"
            case .schedule: "clock"
            case .run: "play.rectangle"
            case .manualCopy: "doc.on.doc"
            }
        }

        var summary: String {
            switch self {
            case .status: "Calendar access, background sync and health."
            case .calendars: "Gather events into the consolidated calendar (fan-in) and send sanitized busy blocks back out (fan-out)."
            case .schedule: "How often the background sync runs, and which dates it covers."
            case .run: "Preview or run the consolidated sync now, and inspect every planned change."
            case .manualCopy: "Copy events once from one calendar to another."
            }
        }
    }

    @State private var page: Page?

    var body: some View {
        NavigationSplitView {
            List(Page.allCases, selection: $page) { page in
                Label(page.rawValue, systemImage: page.systemImage)
                    .tag(page)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            let current = page ?? .status
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(current.rawValue)
                        .font(.title2.weight(.semibold))
                    Text(current.summary)
                        .foregroundStyle(.secondary)
                }
                if let installLocationWarning = viewModel.installLocationWarning {
                    Label(installLocationWarning, systemImage: "arrow.down.app")
                        .foregroundStyle(.orange)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                }
                if let startupError = viewModel.startupError {
                    Label(startupError, systemImage: "exclamationmark.octagon.fill")
                        .foregroundStyle(.red)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                }
                if viewModel.isDemo {
                    Label("Demo mode: sample calendars. Nothing is read or written.", systemImage: "theatermasks")
                        .foregroundStyle(.secondary)
                }
                pageContent(current)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onAppear {
            if page == nil {
                // `-initialPage "Fan-Out"` on launch opens a specific page (used for screenshots and support).
                if let requested = UserDefaults.standard.string(forKey: "initialPage").flatMap(Page.init(rawValue:)) {
                    page = requested
                } else {
                    page = viewModel.mode == .singleCopy ? .manualCopy : .status
                }
            }
        }
        .task {
            await exportScreenshotsIfRequested()
        }
        .onChange(of: page) { _, newPage in
            guard let newPage else { return }
            let mode: BridgeViewModel.Mode = newPage == .manualCopy ? .singleCopy : .consolidatedSync
            if viewModel.mode != mode {
                viewModel.setMode(mode)
            }
        }
        .alert("Remove Everything CoordinatedCalendar Created?", isPresented: $showingRemoveEverythingConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Remove Everything", role: .destructive) {
                viewModel.removeEverything()
                page = .run
            }
        } message: {
            Text("This removes the background jobs, then permanently deletes every event CoordinatedCalendar created, in every calendar: the consolidated copies and all busy blocks. Your own events are never touched. This cannot be undone.")
        }
    }

    /// With `-demoMode YES -exportScreenshots DIR`, saves each page's window as DIR/<page>.png and quits.
    /// Used to make README screenshots from sample data; the app images its own window.
    @MainActor
    private func exportScreenshotsIfRequested() async {
        guard viewModel.isDemo, let directory = UserDefaults.standard.string(forKey: "exportScreenshots") else { return }
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Light appearance and the window's frame view, so the capture includes an opaque background.
        NSApplication.shared.appearance = NSAppearance(named: .aqua)
        for target in Page.allCases {
            page = target
            try? await Task.sleep(for: .milliseconds(1200))
            guard let window = NSApplication.shared.windows.first(where: \.isVisible),
                  let view = window.contentView?.superview ?? window.contentView,
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            else { continue }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let name = target.rawValue.lowercased().replacingOccurrences(of: " & ", with: "-").replacingOccurrences(of: " ", with: "-")
            try? bitmap.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("\(name).png"))
        }
        NSApplication.shared.terminate(nil)
    }

    @ViewBuilder
    private func pageContent(_ page: Page) -> some View {
        switch page {
        case .status:
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    permissionSection
                    backgroundSyncSection
                    backgroundJobsSection
                    setupSummarySection
                    uninstallSection
                }
            }
        case .calendars:
            CalendarFlowView(viewModel: viewModel)
        case .schedule:
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    scheduleSection
                    dateSection
                }
            }
        case .run:
            automationRunControls
            resultsPanel
        case .manualCopy:
            HStack(alignment: .top, spacing: 16) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        calendarSection
                        dateSection
                        transformSection
                        runControls
                    }
                }
                .frame(width: 340)
                VStack(alignment: .leading, spacing: 12) {
                    resultsPanel
                }
            }
        }
    }

    /// Summary counts, filters, the preview table and the selected row's details.
    @ViewBuilder
    private var resultsPanel: some View {
        HStack {
            Text(viewModel.statusText)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            ProgressView(value: viewModel.progress)
                .frame(width: 160)
        }
        resultSummary
        messageControls
        previewTable
        previewDetail
    }

    private var selectedPreview: SyncEventPreview? {
        viewModel.result.previews.first { $0.id == selectedPreviewID }
    }

    private var consolidatedCalendarName: String? {
        guard let consolidatedCalendarKey = viewModel.consolidatedCalendarKey else {
            return nil
        }
        return viewModel.calendars.first { $0.stableKey == consolidatedCalendarKey }?.displayName
    }

    private var previewTable: some View {
        Table(filteredPreviews, selection: $selectedPreviewID) {
            TableColumn("Action") { preview in
                HStack(spacing: 6) {
                    Circle()
                        .fill(directionColor(for: preview))
                        .frame(width: 7, height: 7)
                    previewText(preview.action.rawValue, for: preview)
                }
            }
            .width(min: 110, ideal: 130)

            TableColumn("Source Calendar") { preview in
                previewText(preview.sourceCalendarName ?? "", for: preview)
            }
            .width(min: 140, ideal: 260)

            TableColumn("Destination Calendar") { preview in
                previewText(preview.destinationCalendarName ?? "", for: preview)
            }
            .width(min: 140, ideal: 260)

            TableColumn("Source Title") { preview in
                previewText(preview.sourceTitle, for: preview)
            }
            .width(min: 140, ideal: 260)

            TableColumn("Destination Title") { preview in
                previewText(preview.destinationTitle ?? "", for: preview)
            }
            .width(min: 140, ideal: 260)

            TableColumn("Start") { preview in
                previewText(preview.startDate.formatted(date: .abbreviated, time: .omitted), for: preview)
            }
            .width(min: 100, ideal: 120)

            TableColumn("Source Free/Busy") { preview in
                previewText(preview.sourceAvailability ?? "", for: preview)
            }
            .width(min: 120, ideal: 150)

            TableColumn("Result Free/Busy") { preview in
                previewText(preview.resultingAvailability ?? "", for: preview)
            }
            .width(min: 120, ideal: 150)

            TableColumn("Message") { preview in
                previewText(preview.message, for: preview)
            }
            .width(min: 180, ideal: 320)
        }
        .frame(minHeight: 260, maxHeight: .infinity)
        .overlay {
            if filteredPreviews.isEmpty {
                Text(viewModel.result.previews.isEmpty ? "No preview rows yet." : "No rows match the current filters.")
                    .foregroundStyle(.secondary)
                    .allowsHitTesting(false)
            }
        }
    }

    private func previewText(_ value: String, for preview: SyncEventPreview) -> some View {
        Text(value)
            .foregroundStyle(preview.action == .create ? Color(nsColor: .systemGreen) : Color.primary)
            .lineLimit(1)
            .help(value)
    }

    private func directionColor(for preview: SyncEventPreview) -> Color {
        if preview.destinationCalendarName == consolidatedCalendarName {
            return .blue
        }
        if preview.sourceCalendarName == consolidatedCalendarName {
            return .orange
        }
        return .clear
    }

    private var filteredPreviews: [SyncEventPreview] {
        let trimmedFilter = messageFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        var previews = viewModel.result.previews
        if onlyShowNewAndChanged {
            previews = previews.filter { $0.action != .skipDuplicate }
        }
        if hideBridgeCreatedSkips {
            previews = previews.filter { $0.message != "Skipped CoordinatedCalendar-created event" }
        }
        if !trimmedFilter.isEmpty {
            previews = previews.filter {
                $0.message.localizedCaseInsensitiveContains(trimmedFilter)
            }
        }

        switch messageSort {
        case .original:
            return previews
        case .ascending:
            return previews.sorted {
                let comparison = $0.message.localizedCaseInsensitiveCompare($1.message)
                if comparison == .orderedSame {
                    return $0.startDate < $1.startDate
                }
                return comparison == .orderedAscending
            }
        case .descending:
            return previews.sorted {
                let comparison = $0.message.localizedCaseInsensitiveCompare($1.message)
                if comparison == .orderedSame {
                    return $0.startDate < $1.startDate
                }
                return comparison == .orderedDescending
            }
        }
    }

    private var messageControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                TextField("Filter messages", text: $messageFilter)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)

                Picker("Message sort", selection: $messageSort) {
                    ForEach(MessageSort.allCases) { sort in
                        Text(sort.rawValue).tag(sort)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 320)

                Spacer()

                Text("\(filteredPreviews.count) of \(viewModel.result.previews.count)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            HStack(spacing: 14) {
                Toggle("Only show new and changed", isOn: $onlyShowNewAndChanged)
                    .toggleStyle(.checkbox)

                Toggle("Hide CoordinatedCalendar-created skips", isOn: $hideBridgeCreatedSkips)
                    .toggleStyle(.checkbox)

                if !messageFilter.isEmpty || messageSort != .original || onlyShowNewAndChanged || hideBridgeCreatedSkips {
                    Button("Clear") {
                        messageFilter = ""
                        messageSort = .original
                        onlyShowNewAndChanged = false
                        hideBridgeCreatedSkips = false
                    }
                }

                Spacer()
            }
        }
    }

    private var previewDetail: some View {
        GroupBox("Selected Row Details") {
            ScrollView(.vertical) {
                if let preview = selectedPreview {
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                        detailRow("Action", preview.action.rawValue)
                        detailRow("Source Calendar", preview.sourceCalendarName ?? "")
                        detailRow("Destination Calendar", preview.destinationCalendarName ?? "")
                        detailRow("Source Title", preview.sourceTitle)
                        detailRow("Transformed Destination", preview.destinationTitle ?? "")
                        detailRow("Start", preview.startDate.formatted(date: .abbreviated, time: .shortened))
                        detailRow("Source Free/Busy", preview.sourceAvailability ?? "")
                        detailRow("Result Free/Busy", preview.resultingAvailability ?? "")
                        detailRow("Message", preview.message)
                        detailRow("Transformations", preview.transformationSummary ?? "No transformation details recorded.")
                    }
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("Select a row to inspect origin, destination, and transformations.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxHeight: 180)
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var permissionSection: some View {
        GroupBox("Calendar Access") {
            VStack(alignment: .leading, spacing: 10) {
                Text("CoordinatedCalendar needs full Calendar access to read events from your calendars and write copies. Everything stays on this Mac; it calls no external service.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack {
                    Text(permissionLabel)
                    Spacer()
                    Button("Grant Access") {
                        viewModel.requestAccess()
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var calendarSection: some View {
        GroupBox("Calendars") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Source", selection: binding(\.sourceCalendarKey)) {
                    ForEach(viewModel.calendars) { calendar in
                        Text(calendar.displayName).tag(Optional(calendar.stableKey))
                    }
                }
                Picker("Destination", selection: binding(\.destinationCalendarKey)) {
                    ForEach(viewModel.calendars.filter(\.allowsContentModifications)) { calendar in
                        Text(calendar.displayName).tag(Optional(calendar.stableKey))
                    }
                }
                Button("Refresh Calendars") {
                    viewModel.refreshCalendars()
                }
            }
        }
    }

    private var dateSection: some View {
        GroupBox("Date Window") {
            VStack(alignment: .leading, spacing: 12) {
                DatePicker("Start", selection: binding(\.startDate), displayedComponents: [.date, .hourAndMinute])
                DatePicker("End", selection: binding(\.endDate), displayedComponents: [.date, .hourAndMinute])
            }
        }
    }

    private var scheduleSection: some View {
        GroupBox("Background Sync") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Run every", selection: Binding(
                    get: { viewModel.syncInterval },
                    set: { viewModel.setSyncInterval($0) }
                )) {
                    ForEach(scheduleOptions, id: \.seconds) { option in
                        Text(option.label).tag(option.seconds)
                    }
                }
                .frame(maxWidth: 260)
                Text("Each run does every fan-in, then every fan-out. After changing the interval or the date window, click Submit Background Jobs on the Status page to apply them. Calendar choices, the busy block title and skip settings apply on the next run without resubmitting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    private var backgroundSyncSection: some View {
        GroupBox("Background Sync") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: backgroundHealthProblems.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(backgroundHealthProblems.isEmpty ? .green : .orange)
                    Text(backgroundHealthProblems.isEmpty ? "Healthy" : "Needs attention")
                        .font(.headline)
                    Spacer()
                    Button("Refresh") {
                        viewModel.refreshSyncStatus()
                    }
                }
                if !viewModel.backgroundJobsInstalled {
                    Text("Background jobs are not installed. Set up Fan-In, Fan-Out and Schedule, then submit them below.")
                        .foregroundStyle(.secondary)
                }
                ForEach(backgroundHealthProblems, id: \.self) { problem in
                    Text(problem)
                        .foregroundStyle(.orange)
                }
                if let lastSync = viewModel.lastSync {
                    Text("Last sync \(lastSync.finishedAt.formatted(date: .abbreviated, time: .shortened)): \(lastSync.scanned) scanned, \(lastSync.created) created, \(lastSync.updated) updated, \(lastSync.deleted) deleted, \(lastSync.failed) failed.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Submit Background Jobs") {
                        viewModel.submitBackgroundJobs()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.isRunning)
                    Button("Remove Background Jobs") {
                        viewModel.removeBackgroundJobs()
                    }
                    .disabled(viewModel.isRunning || !viewModel.backgroundJobsInstalled)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var backgroundJobsSection: some View {
        GroupBox("Background Jobs") {
            VStack(alignment: .leading, spacing: 12) {
                if viewModel.backgroundJobs.isEmpty {
                    Text("No background jobs are installed. Submit Background Jobs above to install the sync and health-check jobs.")
                        .foregroundStyle(.secondary)
                }
                ForEach(viewModel.backgroundJobs) { job in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Image(systemName: job.isLoaded ? "circle.fill" : "circle")
                                .foregroundStyle(job.isLoaded ? (job.lastExitCode.map { $0 == "0" } ?? true ? .green : .orange) : .secondary)
                                .font(.caption)
                            Text(jobTitle(job))
                                .font(.headline)
                            Text(job.label)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        jobDetailRow("Schedule", "Every \(intervalLabel(job.interval))\(job.runsAtLoad ? ", and at login" : "")")
                        jobDetailRow("State", jobStateText(job))
                        jobDetailRow("Command", job.arguments.map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " "))
                        jobDetailRow("Log", job.logPath)
                        HStack {
                            Button("Open Log") { openLog(job.logPath) }
                            Button("Open Error Log") { openLog(job.errorLogPath) }
                            Button("Show Job File") { revealInFinder(job.plistPath) }
                        }
                        .controlSize(.small)
                        .disabled(viewModel.isDemo)
                    }
                    if job.id != viewModel.backgroundJobs.last?.id {
                        Divider()
                    }
                }
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func jobTitle(_ job: SyncAgentInstaller.JobDetails) -> String {
        if job.label.hasSuffix(".sync") { return "Sync" }
        if job.label.hasSuffix(".health") { return "Health check" }
        return job.label.components(separatedBy: ".").last?.capitalized ?? job.label
    }

    private func jobStateText(_ job: SyncAgentInstaller.JobDetails) -> String {
        guard let state = job.state else { return "Installed but not loaded. Submit Background Jobs to load it." }
        var parts = [state == "running" ? "Running now" : "Loaded, waiting for the next run"]
        if let runs = job.runs { parts.append("\(runs) runs since loaded") }
        if let code = job.lastExitCode { parts.append(code == "0" ? "last run succeeded" : "last exit code \(code)") }
        return parts.joined(separator: "; ")
    }

    private func jobDetailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            Text(value)
                .font(label == "Command" || label == "Log" ? .caption.monospaced() : .callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func intervalLabel(_ seconds: Int) -> String {
        scheduleOptions.first { $0.seconds == seconds }?.label ?? (seconds % 60 == 0 ? "\(seconds / 60) min" : "\(seconds) s")
    }

    private func openLog(_ path: String) {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            viewModel.statusText = "No log yet at \(path)."
        }
    }

    private func revealInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: (path as NSString).expandingTildeInPath)])
    }

    private var uninstallSection: some View {
        GroupBox("Uninstall") {
            VStack(alignment: .leading, spacing: 10) {
                Text("To stop using CoordinatedCalendar, remove everything it created: the background jobs, the consolidated copies and every busy block in your other calendars. Only events carrying its marker are removed; your own events stay. Preview first to see the list.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Preview Removal") {
                        viewModel.previewRemoveEverything()
                        page = .run
                    }
                    .disabled(viewModel.isRunning)
                    Button("Remove Everything…", role: .destructive) {
                        showingRemoveEverythingConfirmation = true
                    }
                    .disabled(viewModel.isRunning)
                }
                Text("Afterwards, delete the app and its folder ~/Library/Application Support/\(AppSupport.folderName) (see the README).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    private var backgroundHealthProblems: [String] {
        guard viewModel.backgroundJobsInstalled else { return [] }
        return SyncHealth.problems(
            status: viewModel.lastSync,
            now: Date(),
            maxAge: TimeInterval(viewModel.syncInterval * 4)
        )
    }

    private var setupSummarySection: some View {
        GroupBox("Setup") {
            VStack(alignment: .leading, spacing: 6) {
                summaryRow("Consolidated calendar", consolidatedCalendarName ?? "Not chosen")
                summaryRow("Contributors", "\(viewModel.contributorCalendarKeys.count) calendars")
                summaryRow("Recipients", "\(viewModel.recipientCalendarKeys.count) calendars")
                summaryRow("Busy block title", viewModel.fanOutTitle.isEmpty ? FreeBusyCompliance.fanOutTitle : viewModel.fanOutTitle)
                summaryRow("Skips", [viewModel.skipFreeEvents ? "Free events" : nil, viewModel.skipDeclinedEvents ? "declined meetings" : nil].compactMap { $0 }.joined(separator: ", ").nonEmpty ?? "Nothing")
                summaryRow("Runs every", scheduleOptions.first { $0.seconds == viewModel.syncInterval }?.label ?? "\(viewModel.syncInterval / 60) min")
            }
            .padding(.vertical, 4)
        }
    }

    private func summaryRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 170, alignment: .leading)
            Text(value)
        }
    }

    private var transformSection: some View {
        GroupBox("Transform") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Copy as free/busy block only", isOn: binding(\.transform.copyAsFreeBusyOnly))
                TextField("Busy block title", text: binding(\.transform.freeBusyTitle))
                    .disabled(!viewModel.settings.transform.copyAsFreeBusyOnly)
                TextField("Title prefix", text: binding(\.transform.titlePrefix))
                    .disabled(viewModel.settings.transform.copyAsFreeBusyOnly)
                TextField("Title suffix", text: binding(\.transform.titleSuffix))
                    .disabled(viewModel.settings.transform.copyAsFreeBusyOnly)
                TextField("Notes footer", text: binding(\.transform.notesFooter), axis: .vertical)
                    .lineLimit(2...4)
                    .disabled(viewModel.settings.transform.copyAsFreeBusyOnly)
                Toggle("Copy location", isOn: binding(\.transform.copyLocation))
                    .disabled(viewModel.settings.transform.copyAsFreeBusyOnly)
                Toggle("Copy notes", isOn: binding(\.transform.copyNotes))
                    .disabled(viewModel.settings.transform.copyAsFreeBusyOnly)
                Toggle("Copy URL", isOn: binding(\.transform.copyURL))
                    .disabled(viewModel.settings.transform.copyAsFreeBusyOnly)
                Toggle("Allow updates to previous copies", isOn: binding(\.updateExistingCopies))
            }
        }
    }

    private var runControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Run")
                .font(.headline)
            HStack {
                Button("Cancel") {
                    viewModel.cancel()
                }
                .disabled(!viewModel.isRunning)
                Spacer()
                Button("Preview Changes") {
                    viewModel.preview()
                }
                .disabled(viewModel.isRunning)
                Button("Execute Copy") {
                    viewModel.copyEvents()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(viewModel.isRunning)
            }
        }
    }

    private var automationRunControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button("Cancel") {
                    viewModel.cancel()
                }
                .disabled(!viewModel.isRunning)
                Spacer()
                Button("Preview Sync") {
                    viewModel.previewConsolidatedSync()
                }
                .disabled(viewModel.isRunning)
                Button("Execute Sync") {
                    viewModel.executeConsolidatedSync()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(viewModel.isRunning)
            }
        }
    }

    private var resultSummary: some View {
        HStack(spacing: 16) {
            count("Scanned", viewModel.result.scanned)
            count("Create", viewModel.result.created)
            count("Delete", viewModel.result.deleted)
            count("Skipped", viewModel.result.skipped)
            count("Updated", viewModel.result.updated)
            count("Blocked", viewModel.result.blocked)
            count("Failed", viewModel.result.failed)
        }
        .font(.callout.monospacedDigit())
    }

    private func count(_ label: String, _ value: Int) -> some View {
        VStack(alignment: .leading) {
            Text("\(value)").font(.headline)
            Text(label).foregroundStyle(.secondary)
        }
        .frame(minWidth: 72, alignment: .leading)
    }

    private var permissionLabel: String {
        switch viewModel.permissionStatus {
        case .notDetermined: "Not requested"
        case .restricted: "Restricted"
        case .denied: "Denied"
        case .authorized: "Authorized"
        case .fullAccess: "Full access"
        case .writeOnly: "Write only"
        @unknown default: "Unknown"
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<BridgeSettings, Value>) -> Binding<Value> {
        Binding(
            get: { viewModel.settings[keyPath: keyPath] },
            set: { viewModel.updateSettings(keyPath, to: $0) }
        )
    }

    private var consolidatedSelection: Binding<String?> {
        Binding(
            get: { viewModel.consolidatedCalendarKey },
            set: { viewModel.setConsolidatedCalendar($0) }
        )
    }

    private var modeSelection: Binding<BridgeViewModel.Mode> {
        Binding(
            get: { viewModel.mode },
            set: { viewModel.setMode($0) }
        )
    }

    private var scheduleOptions: [(label: String, seconds: Int)] {
        [
            ("5 min", 300),
            ("15 min", 900),
            ("30 min", 1_800),
            ("1 hour", 3_600),
            ("4 hours", 14_400),
            ("12 hours", 43_200)
        ]
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
