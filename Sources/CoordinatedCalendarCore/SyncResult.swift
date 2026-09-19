import Foundation

public struct SyncEventPreview: Identifiable, Equatable, Sendable {
    public enum Action: String, Sendable {
        case create
        case skipDuplicate
        case update
        case delete
        case blocked
        case error
    }

    public let id: String
    public let sourceTitle: String
    public let destinationTitle: String?
    public let sourceCalendarName: String?
    public let destinationCalendarName: String?
    public let startDate: Date
    public let action: Action
    public let message: String
    public let sourceAvailability: String?
    public let resultingAvailability: String?
    public let transformationSummary: String?

    public init(
        id: String,
        sourceTitle: String,
        destinationTitle: String?,
        startDate: Date,
        action: Action,
        message: String,
        sourceCalendarName: String? = nil,
        destinationCalendarName: String? = nil,
        sourceAvailability: String? = nil,
        resultingAvailability: String? = nil,
        transformationSummary: String? = nil
    ) {
        self.id = id
        self.sourceTitle = sourceTitle
        self.destinationTitle = destinationTitle
        self.sourceCalendarName = sourceCalendarName
        self.destinationCalendarName = destinationCalendarName
        self.startDate = startDate
        self.action = action
        self.message = message
        self.sourceAvailability = sourceAvailability
        self.resultingAvailability = resultingAvailability
        self.transformationSummary = transformationSummary
    }
}

public struct SyncResult: Equatable, Sendable {
    public var scanned: Int = 0
    public var created: Int = 0
    public var deleted: Int = 0
    public var skipped: Int = 0
    public var updated: Int = 0
    public var blocked: Int = 0
    public var failed: Int = 0
    public var previews: [SyncEventPreview] = []

    public init() {}
}
