import Foundation

public struct BridgeEventMetadata: Codable, Equatable, Sendable {
    public static let markerPrefix = "CoordinatedCalendar:"
    /// The marker prefix a trimmed notes line starts with, if any.
    static func markerPrefix(of line: String) -> String? {
        line.hasPrefix(markerPrefix) ? markerPrefix : nil
    }

    public var version: Int
    public var copyID: String
    public var sourceIdentity: String
    public var sourceCalendarName: String
    public var sourceCalendarKeyHash: String
    public var destinationCalendarName: String
    public var originCalendarName: String
    public var originCalendarKeyHash: String
    public var copyMode: String
    public var fingerprint: String
    public var sourceAvailability: String?
    public var intendedAvailability: String?
    /// True when you declined the source meeting; omitted otherwise, so other markers are unchanged.
    public var declined: Bool?
    /// The source event's own identifier, in the clear. Written only on full-detail copies — the
    /// consolidated calendar is your own hub, so a tool reading it can match a copy to the event it
    /// came from exactly, instead of guessing by title and time. A free/busy copy sits in someone
    /// else's account and never carries these: `FreeBusyCompliance` treats their presence as a
    /// violation and strips them.
    public var sourceEventID: String?
    /// The source event's cross-device identifier, in the clear, under the same rule as `sourceEventID`.
    public var sourceEventExternalID: String?
    /// The source calendar's display name, in the clear, under the same rule as `sourceEventID`.
    /// `sourceCalendarName` stays hashed, so nothing that reads markers today changes meaning.
    public var sourceCalendarPlainName: String?

    public init(
        version: Int = 1,
        copyID: String,
        sourceIdentity: String,
        sourceCalendarName: String,
        sourceCalendarKeyHash: String,
        destinationCalendarName: String,
        originCalendarName: String,
        originCalendarKeyHash: String,
        copyMode: String,
        fingerprint: String,
        sourceAvailability: String? = nil,
        intendedAvailability: String? = nil,
        declined: Bool? = nil,
        sourceEventID: String? = nil,
        sourceEventExternalID: String? = nil,
        sourceCalendarPlainName: String? = nil
    ) {
        self.version = version
        self.copyID = copyID
        self.sourceIdentity = sourceIdentity
        self.sourceCalendarName = sourceCalendarName
        self.sourceCalendarKeyHash = sourceCalendarKeyHash
        self.destinationCalendarName = destinationCalendarName
        self.originCalendarName = originCalendarName
        self.originCalendarKeyHash = originCalendarKeyHash
        self.copyMode = copyMode
        self.fingerprint = fingerprint
        self.sourceAvailability = sourceAvailability
        self.intendedAvailability = intendedAvailability
        self.declined = declined
        self.sourceEventID = sourceEventID
        self.sourceEventExternalID = sourceEventExternalID
        self.sourceCalendarPlainName = sourceCalendarPlainName
    }

    /// Whether this marker names its source in the clear. True is correct on a full-detail copy in
    /// your own consolidated calendar, and never correct on a copy in someone else's calendar.
    public var carriesSourceReference: Bool {
        sourceEventID != nil || sourceEventExternalID != nil || sourceCalendarPlainName != nil
    }

    /// The same marker with everything clear-text about the source removed.
    public var withoutSourceReference: BridgeEventMetadata {
        var stripped = self
        stripped.sourceEventID = nil
        stripped.sourceEventExternalID = nil
        stripped.sourceCalendarPlainName = nil
        return stripped
    }

    /// Namespace hashed into identities and name tokens, so they cannot collide with other hashes.
    static let identityNamespace = "CoordinatedCalendar"

    public static func makeSourceIdentity(
        sourceCalendarName: String,
        sourceEventExternalIdentifier: String?,
        sourceEventIdentifier: String,
        sourceStartDate: Date
    ) -> String {
        EventFingerprint.hash(parts: [
            identityNamespace + "Source",
            sourceCalendarName,
            sourceEventExternalIdentifier ?? sourceEventIdentifier,
            String(format: "%.0f", sourceStartDate.timeIntervalSince1970)
        ])
    }

    public static func makeCopyID(
        sourceIdentity: String,
        destinationCalendarName: String,
        copyMode: String
    ) -> String {
        EventFingerprint.hash(parts: [
            identityNamespace + "Copy",
            sourceIdentity,
            destinationCalendarName,
            copyMode
        ])
    }

    /// Markers sit in the notes of copies on other accounts' calendars, so calendar names are always written
    /// as hashes. Names are the same on every Mac, so the hashes still match across Macs.
    public var encodedMarker: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(withHashedCalendarNames)) ?? Data()
        return Self.markerPrefix + data.base64EncodedString()
    }

    static let hashedNamePrefix = "sha256:"

    /// The form a calendar name takes inside a marker.
    public static func calendarNameToken(_ name: String) -> String {
        hashedNamePrefix + EventFingerprint.hash(parts: [identityNamespace + "CalendarName", name])
    }

    /// Whether a name stored in a marker refers to `name`, in either the hashed form or the plain form older
    /// markers used.
    public static func storedName(_ stored: String, matches name: String) -> Bool {
        stored == name || stored == calendarNameToken(name)
    }

    /// Resolves a stored name to one of `candidates`, or returns it unchanged when it is an older plain name.
    public static func resolveStoredName(_ stored: String, among candidates: [String]) -> String? {
        guard stored.hasPrefix(hashedNamePrefix) else { return stored }
        return candidates.first { calendarNameToken($0) == stored }
    }

    /// True for markers written before calendar names were hashed.
    public var hasPlainCalendarNames: Bool {
        [sourceCalendarName, destinationCalendarName, originCalendarName].contains { !$0.hasPrefix(Self.hashedNamePrefix) }
    }

    public var withHashedCalendarNames: BridgeEventMetadata {
        var hashed = self
        for keyPath in [\BridgeEventMetadata.sourceCalendarName, \.destinationCalendarName, \.originCalendarName]
        where !hashed[keyPath: keyPath].hasPrefix(Self.hashedNamePrefix) {
            hashed[keyPath: keyPath] = Self.calendarNameToken(hashed[keyPath: keyPath])
        }
        return hashed
    }

    public static func parse(from notes: String?) -> BridgeEventMetadata? {
        guard let notes else { return nil }
        for line in notes.components(separatedBy: .newlines).reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let prefix = markerPrefix(of: trimmed) else { continue }
            let payload = String(trimmed.dropFirst(prefix.count))
            guard let data = Data(base64Encoded: payload) else { continue }
            return try? JSONDecoder().decode(BridgeEventMetadata.self, from: data)
        }
        return nil
    }

    public static func notesByAddingMarker(to notes: String?, metadata: BridgeEventMetadata) -> String {
        let cleaned = notesByRemovingMarker(from: notes)
        if cleaned.isEmpty {
            return metadata.encodedMarker
        }
        return "\(cleaned)\n\n\(metadata.encodedMarker)"
    }

    /// Removes marker lines and trailing whitespace, and keeps everything else exactly as written, including
    /// leading indentation and CRLF line endings (a CRLF is one Character, so it stays one line break).
    public static func notesByRemovingMarker(from notes: String?) -> String {
        guard let notes else { return "" }
        var kept = ""
        var line = ""
        func flush(terminator: Character?) {
            if markerPrefix(of: line.trimmingCharacters(in: .whitespaces)) == nil {
                kept += line
                if let terminator {
                    kept.append(terminator)
                }
            }
            line = ""
        }
        for character in notes {
            if character.isNewline {
                flush(terminator: character)
            } else {
                line.append(character)
            }
        }
        flush(terminator: nil)
        while let last = kept.last, last.isWhitespace {
            kept.removeLast()
        }
        return kept
    }
}
