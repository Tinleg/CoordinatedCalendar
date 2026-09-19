import EventKit
import Foundation

public struct CalendarIdentity: Codable, Hashable, Identifiable, Sendable {
    public let sourceIdentifier: String
    public let sourceTitle: String
    public let sourceType: String
    public let calendarIdentifier: String
    public let calendarTitle: String
    public let allowsContentModifications: Bool
    public let supportedAvailabilities: [String]

    public var id: String { stableKey }
    public var stableKey: String { "\(sourceIdentifier)::\(calendarIdentifier)" }
    public var displayName: String { "\(sourceTitle) / \(calendarTitle)" }

    private enum CodingKeys: String, CodingKey {
        case sourceIdentifier
        case sourceTitle
        case sourceType
        case calendarIdentifier
        case calendarTitle
        case allowsContentModifications
        case supportedAvailabilities
    }

    public init(
        sourceIdentifier: String,
        sourceTitle: String,
        sourceType: String = "unknown",
        calendarIdentifier: String,
        calendarTitle: String,
        allowsContentModifications: Bool,
        supportedAvailabilities: [String] = []
    ) {
        self.sourceIdentifier = sourceIdentifier
        self.sourceTitle = sourceTitle
        self.sourceType = sourceType
        self.calendarIdentifier = calendarIdentifier
        self.calendarTitle = calendarTitle
        self.allowsContentModifications = allowsContentModifications
        self.supportedAvailabilities = supportedAvailabilities
    }

    public init(calendar: EKCalendar) {
        self.init(
            sourceIdentifier: calendar.source.sourceIdentifier,
            sourceTitle: calendar.source.title,
            sourceType: Self.sourceTypeName(for: calendar.source.sourceType),
            calendarIdentifier: calendar.calendarIdentifier,
            calendarTitle: calendar.title,
            allowsContentModifications: calendar.allowsContentModifications,
            supportedAvailabilities: Self.supportedAvailabilities(for: calendar.supportedEventAvailabilities)
        )
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            sourceIdentifier: try container.decode(String.self, forKey: .sourceIdentifier),
            sourceTitle: try container.decode(String.self, forKey: .sourceTitle),
            sourceType: try container.decodeIfPresent(String.self, forKey: .sourceType) ?? "unknown",
            calendarIdentifier: try container.decode(String.self, forKey: .calendarIdentifier),
            calendarTitle: try container.decode(String.self, forKey: .calendarTitle),
            allowsContentModifications: try container.decode(Bool.self, forKey: .allowsContentModifications),
            supportedAvailabilities: try container.decodeIfPresent([String].self, forKey: .supportedAvailabilities) ?? []
        )
    }

    private static func supportedAvailabilities(for mask: EKCalendarEventAvailabilityMask) -> [String] {
        var values: [String] = []
        if mask.contains(.free) {
            values.append("free")
        }
        if mask.contains(.busy) {
            values.append("busy")
        }
        if mask.contains(.tentative) {
            values.append("tentative")
        }
        if mask.contains(.unavailable) {
            values.append("unavailable")
        }
        return values
    }

    private static func sourceTypeName(for type: EKSourceType) -> String {
        switch type {
        case .local:
            "local"
        case .exchange:
            "exchange"
        case .calDAV:
            "calDAV"
        case .mobileMe:
            "mobileMe"
        case .subscribed:
            "subscribed"
        case .birthdays:
            "birthdays"
        @unknown default:
            "unknown"
        }
    }
}
