import EventKit
import Foundation

/// Rules for what a free/busy (fan-out) copy may carry: its busy title, times, availability, privacy,
/// and the CoordinatedCalendar notes marker. Everything else is stripped.
public enum FreeBusyCompliance {
    public static let fanOutTitle = "Busy - Other"

    /// Describes each field on a free/busy copy that must be stripped. `expectedTitle` is nil when the
    /// title is intentionally source-derived (the `--origin-title` copy option), so it is not checked.
    public static func violations(of event: EKEvent, expectedTitle: String?) -> [String] {
        var violations: [String] = []
        if BridgeEventMetadata.parse(from: event.notes)?.carriesSourceReference == true {
            // Clear-text source references belong to the consolidated calendar alone. One here means
            // a copy was made as full detail and later routed as free/busy, or written by an older
            // build; either way it names another calendar's event inside someone else's account.
            violations.append("source reference")
        }
        if let expectedTitle, event.title != expectedTitle {
            violations.append("title")
        }
        if !(event.location ?? "").isEmpty || event.structuredLocation != nil {
            violations.append("location")
        }
        if event.url != nil {
            violations.append("URL")
        }
        if !(event.alarms ?? []).isEmpty {
            violations.append("alarms")
        }
        if event.hasRecurrenceRules {
            violations.append("recurrence")
        }
        if !BridgeEventMetadata.notesByRemovingMarker(from: event.notes).isEmpty {
            violations.append("notes")
        }
        return violations
    }

    /// Strips a non-recurring free/busy copy in place. Recurring copies are removed and recreated instead.
    public static func strip(_ event: EKEvent, metadata: BridgeEventMetadata, expectedTitle: String?) {
        if let expectedTitle {
            event.title = expectedTitle
        }
        event.structuredLocation = nil
        event.location = nil
        event.url = nil
        event.alarms = nil
        event.notes = BridgeEventMetadata.notesByAddingMarker(to: nil, metadata: metadata.withoutSourceReference)
    }
}
