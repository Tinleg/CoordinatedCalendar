import CoordinatedCalendarCore
import EventKit
import Foundation

/// `--watch`: stays running as its own background job and starts the sync job shortly after the calendars
/// change, instead of leaving a change to wait for the next scheduled run.
///
/// EventKit posts a change notification to every process with a store open whenever the calendar database
/// changes, including when an account brings down changes made elsewhere (checked 2026-09-23: another
/// process's edit arrived within a second, and the account echoing it back a few seconds later arrived as
/// a second notification). The watcher does no syncing itself: it starts the sync job, so launchd keeps
/// every run in one process, one at a time, with its usual log. The sync's own writes notify the watcher
/// too; the run they trigger finds its own work already done, and the one after that stops at the
/// signature check (SyncSignature).
@MainActor
enum ChangeWatcher {
    private final class Pending {
        var debouncer = ChangeDebouncer()
    }

    static func run() async -> Int32 {
        let store = EKEventStore()
        let pending = Pending()
        // Observed for the life of the process, which is the life of the job.
        let changes = AsyncStream<Date> { continuation in
            _ = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { _ in
                continuation.yield(Date())
            }
        }
        Task { @MainActor in
            for await date in changes {
                pending.debouncer.recordChange(at: date)
            }
        }
        log("watching for calendar changes")

        while true {
            try? await Task.sleep(for: .seconds(2))
            guard pending.debouncer.isDue(at: Date()) else { continue }
            let count = pending.debouncer.pendingChanges
            pending.debouncer.reset()
            // A change that arrives while a sync is already running may have been read too late for it, so
            // wait for that run to end and start another; changes seen meanwhile are simply included.
            var waited = 0
            while SyncAgentInstaller.isRunning(label: SyncAgentInstaller.syncLabel), waited < 1200 {
                try? await Task.sleep(for: .seconds(3))
                waited += 3
            }
            do {
                try SyncAgentInstaller.startNow(label: SyncAgentInstaller.syncLabel)
                log("calendars changed (\(count) notification\(count == 1 ? "" : "s")); started a sync")
            } catch {
                log("calendars changed, but the sync job could not be started: \(error.localizedDescription)")
            }
        }
    }

    private static func log(_ message: String) {
        print("\(Date().ISO8601Format()) \(message)")
        fflush(stdout)
    }
}
