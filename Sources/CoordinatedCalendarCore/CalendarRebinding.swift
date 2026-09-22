import Foundation

/// Re-attaches selected calendars that came back under a new identifier.
///
/// macOS gives a calendar a new identifier when its account is removed and added again — the usual fix
/// when Calendar stops showing an account's events. Settings store identifiers, so without this the
/// calendar silently drops out of syncing. Names survive a re-add, so settings also record the name each
/// selected identifier had, and a vanished identifier is rebound to the one calendar now carrying it.
public enum CalendarRebinding {
    public struct Available: Equatable, Sendable {
        public var key: String
        public var name: String
        public init(key: String, name: String) {
            self.key = key
            self.name = name
        }
    }

    /// Selected keys that no longer name any calendar, mapped to their replacement. A key is rebound only
    /// when exactly one current calendar carries the name recorded for it, that calendar is not already
    /// selected, and no other vanished key wants it. Anything less is left alone: rebinding to the wrong
    /// calendar would copy the wrong events.
    public static func rebinds(selected: [String], recordedNames: [String: String], available: [Available]) -> [String: String] {
        let availableKeys = Set(available.map(\.key))
        let selectedKeys = Set(selected)
        var candidates: [String: String] = [:]
        for key in Set(selected) where !availableKeys.contains(key) {
            guard let name = recordedNames[key] else { continue }
            let matches = available.filter { $0.name == name && !selectedKeys.contains($0.key) }
            if matches.count == 1 {
                candidates[key] = matches[0].key
            }
        }
        let wanted = Dictionary(grouping: candidates.values, by: { $0 })
        return candidates.filter { wanted[$0.value]?.count == 1 }
    }

    /// Selected keys that are missing and could not be rebound, with the name recorded for them if any.
    public static func stillMissing(selected: [String], recordedNames: [String: String], available: [Available],
                                    rebinds: [String: String]) -> [(key: String, name: String?)] {
        let availableKeys = Set(available.map(\.key))
        return Array(Set(selected))
            .filter { !availableKeys.contains($0) && rebinds[$0] == nil }
            .sorted()
            .map { ($0, recordedNames[$0]) }
    }
}
