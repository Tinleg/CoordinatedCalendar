import EventKit
import Foundation

/// Source-event metadata that EventKit will not write onto a copy (participants and status are read-only,
/// and each occurrence is copied as its own event), rendered as a notes block for full-detail copies.
public enum EventDetailsSummary {
    public static let header = "Source details:"
    public static let attendeeLimit = 50

    public struct Participant: Equatable, Sendable {
        public var name: String?
        public var email: String?
        public var status: String?

        public init(name: String?, email: String?, status: String?) {
            self.name = name
            self.email = email
            self.status = status
        }

        var display: String {
            let identity = switch (name?.nilIfBlank, email?.nilIfBlank) {
            case let (name?, email?) where name.caseInsensitiveCompare(email) != .orderedSame: "\(name) <\(email)>"
            case let (name?, _): name
            case let (nil, email?): email
            case (nil, nil): "Unknown"
            }
            return status.map { "\(identity) (\($0))" } ?? identity
        }
    }

    /// Returns nil when there is nothing to add, so copies of plain events keep their notes and fingerprint.
    public static func text(
        organizer: Participant?,
        attendees: [Participant],
        status: String?,
        recurrence: String?,
        declinedByYou: Bool = false
    ) -> String? {
        var lines: [String] = []
        if declinedByYou {
            // Fan-out skips declined meetings; this line records why in the consolidated copy. Downstream
            // consumers parse the exact "Your response: declined" line; keep the form.
            lines.append("Your response: declined")
        }
        if let status {
            // Downstream consumers parse the exact "Status: canceled" line as a cancelled event; keep the form.
            lines.append("Status: \(status)")
        }
        if let organizer {
            lines.append("Organizer: \(organizer.display)")
        }
        if !attendees.isEmpty {
            // EventKit returns attendees in no stable order; sorting keeps the notes and fingerprint stable.
            let shown = attendees.map(\.display)
                .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
                .prefix(attendeeLimit)
            let more = attendees.count > attendeeLimit ? "; and \(attendees.count - attendeeLimit) more" : ""
            lines.append("Attendees: \(shown.joined(separator: "; "))\(more)")
        }
        if let recurrence {
            lines.append("Repeats: \(recurrence)")
        }
        guard !lines.isEmpty else { return nil }
        return ([header] + lines).joined(separator: "\n")
    }

    public static func text(for event: any StoredEvent) -> String? {
        let organizer = event.organizer.map(participant(_:))
        let attendees = (event.attendees ?? [])
            .filter { $0.url != event.organizer?.url }
            .map(participant(_:))
        return text(
            organizer: organizer,
            attendees: attendees,
            status: statusName(event.status),
            recurrence: event.recurrenceRules?.first.map(recurrenceDescription(_:)),
            declinedByYou: declinedByCurrentUser(event)
        )
    }

    /// Whether you are an attendee of `event` and declined it.
    public static func declinedByCurrentUser(_ event: any StoredEvent) -> Bool {
        event.attendees?.contains { $0.isCurrentUser && $0.participantStatus == .declined } ?? false
    }

    /// Plain-language rule, e.g. "every 2 weeks on Mon, Wed until 2026-12-31".
    public static func recurrenceDescription(frequency: EKRecurrenceFrequency, interval: Int, weekdays: [Int], until: Date?, count: Int?) -> String {
        let unit = switch frequency {
        case .daily: "day"
        case .weekly: "week"
        case .monthly: "month"
        case .yearly: "year"
        @unknown default: "period"
        }
        var text = interval <= 1 ? "every \(unit)" : "every \(interval) \(unit)s"
        let symbols = Calendar(identifier: .gregorian).shortWeekdaySymbols
        let days = weekdays.sorted().compactMap { (1...7).contains($0) ? symbols[$0 - 1] : nil }
        if !days.isEmpty {
            text += " on \(days.joined(separator: ", "))"
        }
        if let until {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            text += " until \(formatter.string(from: until))"
        } else if let count {
            text += ", \(count) times"
        }
        return text
    }

    private static func recurrenceDescription(_ rule: EKRecurrenceRule) -> String {
        recurrenceDescription(
            frequency: rule.frequency,
            interval: rule.interval,
            weekdays: rule.daysOfTheWeek?.map(\.dayOfTheWeek.rawValue) ?? [],
            until: rule.recurrenceEnd?.endDate,
            count: rule.recurrenceEnd.flatMap { $0.occurrenceCount > 0 ? $0.occurrenceCount : nil }
        )
    }

    private static func participant(_ participant: EKParticipant) -> Participant {
        let email = participant.url.absoluteString.lowercased().hasPrefix("mailto:")
            ? String(participant.url.absoluteString.dropFirst("mailto:".count))
            : nil
        return Participant(name: participant.name, email: email, status: participantStatusName(participant.participantStatus))
    }

    private static func statusName(_ status: EKEventStatus) -> String? {
        switch status {
        // Confirmed is the norm for scheduled meetings, so only the exceptions are worth recording.
        case .confirmed: nil
        case .tentative: "tentative"
        case .canceled: "canceled"
        case .none: nil
        @unknown default: nil
        }
    }

    private static func participantStatusName(_ status: EKParticipantStatus) -> String? {
        switch status {
        case .accepted: "accepted"
        case .declined: "declined"
        case .tentative: "tentative"
        case .pending: "no response"
        case .delegated: "delegated"
        case .completed: "completed"
        case .inProcess: "in process"
        case .unknown: nil
        @unknown default: nil
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
