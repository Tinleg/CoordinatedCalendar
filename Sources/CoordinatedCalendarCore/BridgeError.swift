import Foundation

public enum BridgeError: LocalizedError, Equatable {
    case calendarAccessDenied
    case sourceCalendarMissing
    case destinationCalendarMissing
    case destinationCalendarReadOnly(String)
    case dateWindowInvalid
    case sameSourceAndDestination
    case existingCopyNeedsUpdate(String)

    public var errorDescription: String? {
        switch self {
        case .calendarAccessDenied:
            "Calendar full access is required. Grant access in System Settings > Privacy & Security > Calendars."
        case .sourceCalendarMissing:
            "Choose a source calendar."
        case .destinationCalendarMissing:
            "Choose a destination calendar."
        case .destinationCalendarReadOnly(let title):
            "The destination calendar \"\(title)\" is read-only."
        case .dateWindowInvalid:
            "The end date must be after the start date."
        case .sameSourceAndDestination:
            "Choose two different calendars."
        case .existingCopyNeedsUpdate(let title):
            "A previous copy of \"\(title)\" exists but differs. Enable updates to overwrite copied fields."
        }
    }
}
