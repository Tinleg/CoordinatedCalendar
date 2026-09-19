import CryptoKit
import EventKit
import Foundation

public enum EventFingerprint {
    public static func hash(parts: [String]) -> String {
        let joined = parts.joined(separator: "\u{1f}")
        let digest = SHA256.hash(data: Data(joined.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func fingerprint(
        sourceCalendarKey: String,
        title: String,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool,
        location: String?,
        url: URL?,
        recurrenceRuleDescriptions: [String]
    ) -> String {
        hash(parts: [
            sourceCalendarKey,
            title,
            String(format: "%.0f", startDate.timeIntervalSince1970),
            String(format: "%.0f", endDate.timeIntervalSince1970),
            isAllDay ? "allDay" : "timed",
            location ?? "",
            url?.absoluteString ?? "",
            recurrenceRuleDescriptions.sorted().joined(separator: "|")
        ])
    }

    public static func fingerprint(event: EKEvent, sourceCalendarKey: String) -> String {
        fingerprint(
            sourceCalendarKey: sourceCalendarKey,
            title: event.title ?? "",
            startDate: event.startDate,
            endDate: event.endDate,
            isAllDay: event.isAllDay,
            location: event.location,
            url: event.url,
            recurrenceRuleDescriptions: event.recurrenceRules?.map(\.description) ?? []
        )
    }

    public static func fingerprint(
        event: EKEvent,
        sourceCalendarKey: String,
        transform: TransformSettings,
        sourceCalendarName: String? = nil,
        originCalendarName: String? = nil
    ) -> String {
        var parts = [
            fingerprint(event: event, sourceCalendarKey: sourceCalendarKey),
            transform.destinationTitle(
                for: event.title ?? "",
                sourceCalendarName: sourceCalendarName,
                originCalendarName: originCalendarName
            ),
            transform.destinationNotes(for: event.notes) ?? "",
            transform.copyAsFreeBusyOnly ? "freeBusy" : "fullDetails",
            transform.markFreeBusyEventsPrivate ? "freeBusyPrivate" : "freeBusyDefaultPrivacy",
            "availability:\(transform.destinationAvailability.rawValue)",
            "resolvedAvailability:\(availabilityFingerprint(for: event, transform: transform))",
            transform.includeOriginCalendarInFreeBusyTitle ? "includeOrigin" : "noOrigin",
            originCalendarName ?? "",
            transform.includeSourceCalendarInTitle ? "includeSourceCalendar" : "noSourceCalendar",
            sourceCalendarName ?? "",
            transform.copyLocation ? "copyLocation" : "noLocation",
            transform.copyURL ? "copyURL" : "noURL"
        ]
        // Appended only when coordinates are copied, so copies without a place keep their prior fingerprint.
        if !transform.copyAsFreeBusyOnly, transform.copyLocation, let place = geoPlace(of: event),
           let coordinate = place.geoLocation?.coordinate {
            parts.append(String(format: "place:%.5f,%.5f", coordinate.latitude, coordinate.longitude))
        }
        // Copies of notes with CRLF line endings or leading whitespace were altered before notes were kept
        // verbatim; this part re-copies only those, once.
        if !transform.copyAsFreeBusyOnly, transform.copyNotes,
           let notes = event.notes, notes.contains("\r") || notes.first?.isWhitespace == true {
            parts.append("notes:verbatim")
        }
        // Likewise appended only when the source has participants, a notable status, or recurrence.
        if !transform.copyAsFreeBusyOnly, let details = EventDetailsSummary.text(for: event) {
            parts.append("details:\(details)")
        }
        return hash(parts: parts)
    }

    /// The event's structured location when it carries coordinates.
    public static func geoPlace(of event: EKEvent) -> EKStructuredLocation? {
        guard let place = event.structuredLocation, place.geoLocation != nil else {
            return nil
        }
        return place
    }

    private static func availabilityFingerprint(for event: EKEvent, transform: TransformSettings) -> String {
        guard transform.destinationAvailability == .preserve else {
            return "forced:\(transform.destinationAvailability.rawValue)"
        }

        if let metadata = BridgeEventMetadata.parse(from: event.notes),
           let metadataAvailability = metadata.intendedAvailability ?? metadata.sourceAvailability {
            return "metadata:\(metadataAvailability)"
        }

        return "event:\(event.availability.rawValue)"
    }
}
