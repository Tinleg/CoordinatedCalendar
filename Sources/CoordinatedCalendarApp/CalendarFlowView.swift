import CoordinatedCalendarCore
import SwiftUI

/// Fan-in and fan-out on one page: contributors on the left, the consolidated calendar in the middle and
/// recipients on the right, joined by curves from each checked contributor into the consolidated calendar
/// and from it out to each checked recipient.
struct CalendarFlowView: View {
    @ObservedObject var viewModel: BridgeViewModel
    /// Height of the taller column header, so the consolidated card centers on the calendar rows alone.
    @State private var headerHeight: CGFloat = 0

    private static let fanInColor = Color.blue
    private static let fanOutColor = Color.orange

    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 64) {
                contributorsColumn
                    .frame(minWidth: 240, maxWidth: .infinity)
                hubColumn
                    .frame(width: 260)
                    // Rows start below the column headers (plus the column's 8-point spacing).
                    .padding(.top, headerHeight + 8)
                    .frame(maxHeight: .infinity)
                recipientsColumn
                    .frame(minWidth: 300, maxWidth: .infinity)
            }
            .padding(.vertical, 6)
            .onPreferenceChange(HeaderHeightKey.self) { headerHeight = $0 }

            .backgroundPreferenceValue(FlowAnchorKey.self) { anchors in
                GeometryReader { proxy in
                    flowLines(anchors: anchors, proxy: proxy)
                }
                .allowsHitTesting(false)
                // The lines repeat what the checkboxes say; VoiceOver reads those instead.
                .accessibilityHidden(true)
            }
            .animation(.easeInOut(duration: 0.25), value: viewModel.contributorCalendarKeys)
            .animation(.easeInOut(duration: 0.25), value: viewModel.recipientCalendarKeys)
        }
    }

    // MARK: Columns

    private var contributorsColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            columnHeader(
                "Fan-In",
                systemImage: "arrow.down.right.and.arrow.up.left",
                color: Self.fanInColor,
                detail: "Events from checked calendars copy into the consolidated calendar with full details. Read-only calendars such as holidays and birthdays can contribute."
            )
            ForEach(viewModel.calendars.filter { $0.stableKey != viewModel.consolidatedCalendarKey }) { calendar in
                let selected = viewModel.contributorCalendarKeys.contains(calendar.stableKey)
                calendarRow(
                    calendar,
                    selected: selected,
                    color: Self.fanInColor,
                    anchorID: "in:\(calendar.stableKey)"
                )
                if selected, Self.isTripIt(calendar) {
                    tripItNote
                }
            }
        }
    }

    /// TripIt names its calendar feed after itself ("TripIt Feed", "TripIt"), which is all EventKit shows
    /// of a subscription; the feed's address is not available to apps.
    static func isTripIt(_ calendar: CalendarIdentity) -> Bool {
        calendar.calendarTitle.localizedCaseInsensitiveContains("tripit")
            || calendar.sourceTitle.localizedCaseInsensitiveContains("tripit")
    }

    /// TripIt puts an all-day event across every trip, which as a busy block would mark whole days as
    /// taken in every other calendar. Said where the choice is made, so it is not a surprise later.
    private var tripItNote: some View {
        let skipping = viewModel.skipAllDayEvents
        return Label {
            Text(skipping
                ? "TripIt adds an all-day event spanning each whole trip, such as \u{201C}Buffalo, NY, September 2026\u{201D}, alongside its flights, car rentals and hotels. Trip spans are gathered into the consolidated calendar but never become busy blocks, because fan-out skips all-day events. Flights and other timed plans block time as Busy."
                : "TripIt adds an all-day event spanning each whole trip, such as \u{201C}Buffalo, NY, September 2026\u{201D}, alongside its flights, car rentals and hotels. With \u{201C}Skip all-day events\u{201D} off, each trip becomes an all-day busy block for its whole length in every recipient calendar. Turn it on in the Consolidated card so only flights and other timed plans block time.")
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: skipping ? "airplane" : "exclamationmark.triangle")
        }
        .font(.caption)
        .foregroundStyle(skipping ? Color.secondary : Color.orange)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Self.fanInColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private var hubColumn: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 8) {
                Label("Consolidated", systemImage: "square.stack.3d.up.fill")
                    .font(.headline)
                Picker("Consolidated calendar", selection: Binding(
                    get: { viewModel.consolidatedCalendarKey },
                    set: { viewModel.setConsolidatedCalendar($0) }
                )) {
                    Text("Choose calendar").tag(Optional<String>.none)
                    ForEach(viewModel.calendars.filter(\.allowsContentModifications)) { calendar in
                        Text(calendar.displayName).tag(Optional(calendar.stableKey))
                    }
                }
                .labelsHidden()
                .help("Keeps full, readable details of every gathered event. Create it in the Calendar app (File > New Calendar), in an account where that is acceptable.")
                HStack(spacing: 12) {
                    Label("\(viewModel.contributorCalendarKeys.count) in", systemImage: "arrow.right")
                        .foregroundStyle(Self.fanInColor)
                    Label("\(viewModel.recipientCalendarKeys.count) out", systemImage: "arrow.right")
                        .foregroundStyle(Self.fanOutColor)
                }
                .font(.caption.weight(.semibold))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(viewModel.contributorCalendarKeys.count) calendars gathered in, \(viewModel.recipientCalendarKeys.count) receiving busy blocks")
                Divider()
                busyBlockOptions
            }
            .padding(12)
            .background(.background, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 1.5))
            .anchorPreference(key: FlowAnchorKey.self, value: .bounds) { ["hub": $0] }
            Spacer(minLength: 0)
        }
    }

    private var recipientsColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            columnHeader(
                "Fan-Out",
                systemImage: "arrow.up.left.and.arrow.down.right",
                color: Self.fanOutColor,
                detail: "Checked calendars receive a busy block for every consolidated event, except those that came from them. Blocks carry only the busy block title (set in the Consolidated card), times, free/busy status and a hashed marker."
            )
            ForEach(viewModel.calendars.filter { $0.allowsContentModifications && $0.stableKey != viewModel.consolidatedCalendarKey }) { calendar in
                calendarRow(
                    calendar,
                    selected: viewModel.recipientCalendarKeys.contains(calendar.stableKey),
                    color: Self.fanOutColor,
                    anchorID: "out:\(calendar.stableKey)",
                    availability: calendar.stableKey,
                    isRecipient: true
                )
            }
        }
    }

    /// Fan-out settings, shown inside the consolidated card; explanations are hover tooltips.
    private var busyBlockOptions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Busy block title")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(FreeBusyCompliance.fanOutTitle, text: Binding(
                get: { viewModel.fanOutTitle },
                set: { viewModel.setFanOutTitle($0) }
            ))
            .textFieldStyle(.roundedBorder)
            .help("The only text a busy block carries. Leave it blank for \"\(FreeBusyCompliance.fanOutTitle)\". Changing it retitles every existing busy block on the next sync.")
            Toggle("Keep alerts on gathered events", isOn: Binding(
                get: { viewModel.keepAlertsInConsolidated },
                set: { viewModel.setKeepAlertsInConsolidated($0) }
            ))
            .help("Off by default: a gathered copy carries no alert, so a meeting doesn't notify you a second time from the consolidated calendar. Busy blocks never alert either way. Turning this on copies each event's own alerts; turning it off again removes them on the next sync.")
            Toggle("Skip events marked Free", isOn: Binding(
                get: { viewModel.skipFreeEvents },
                set: { viewModel.setSkipFreeEvents($0) }
            ))
            .help("Events marked Free don't take up your time, so they get no busy block. Blocks already made for them are removed on the next sync.")
            Toggle("Skip meetings you declined", isOn: Binding(
                get: { viewModel.skipDeclinedEvents },
                set: { viewModel.setSkipDeclinedEvents($0) }
            ))
            .help("Meetings you declined get no busy block. Blocks already made for them are removed on the next sync.")
            Toggle("Skip all-day events", isOn: Binding(
                get: { viewModel.skipAllDayEvents },
                set: { viewModel.setSkipAllDayEvents($0) }
            ))
            .help("On by default. All-day events get no busy block, even when marked Busy, so a trip or a holiday doesn't block out whole days. They are still gathered into the consolidated calendar. Blocks already made for them are removed on the next sync.")
        }
    }

    private func columnHeader(_ title: String, systemImage: String, color: Color, detail: String) -> some View {
        HStack(spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(color)
            Image(systemName: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .help(detail)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityHint(detail)
        .padding(.bottom, 4)
        .background(GeometryReader { proxy in
            Color.clear.preference(key: HeaderHeightKey.self, value: proxy.size.height)
        })
        // Both headers take the taller height, so both calendar lists start on the same line.
        .frame(minHeight: headerHeight, alignment: .top)
    }

    private func calendarRow(
        _ calendar: CalendarIdentity,
        selected: Bool,
        color: Color,
        anchorID: String,
        availability recipientKey: String? = nil,
        isRecipient: Bool = false
    ) -> some View {
        HStack(alignment: .center, spacing: 8) {
            // Calls the view model directly; a closure parameter here crashes the Swift 6.1 compiler.
            Toggle(isOn: Binding(
                get: { selected },
                set: { enabled in
                    if isRecipient {
                        viewModel.setRecipient(calendar.stableKey, enabled: enabled)
                    } else {
                        viewModel.setContributor(calendar.stableKey, enabled: enabled)
                    }
                }
            )) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(calendar.displayName)
                        .lineLimit(1)
                    Text(capabilities(calendar))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.checkbox)
            Spacer(minLength: 4)
            if let recipientKey {
                Picker("Availability for \(calendar.displayName)", selection: Binding(
                    get: { viewModel.recipientAvailability(for: recipientKey) },
                    set: { viewModel.setRecipientAvailability($0, for: recipientKey) }
                )) {
                    ForEach(viewModel.recipientAvailabilityOptions(for: recipientKey), id: \.self) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .labelsHidden()
                .frame(width: 120)
                .disabled(!selected)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(selected ? color.opacity(0.10) : Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? color.opacity(0.5) : .clear, lineWidth: 1))
        .anchorPreference(key: FlowAnchorKey.self, value: .bounds) { [anchorID: $0] }
    }

    private func capabilities(_ calendar: CalendarIdentity) -> String {
        let access = calendar.allowsContentModifications ? "writable" : "read-only"
        let statuses = calendar.supportedAvailabilities.map(\.capitalized).joined(separator: ", ")
        return [calendar.sourceType, access, statuses.isEmpty ? nil : statuses].compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: Curves

    @ViewBuilder
    private func flowLines(anchors: [String: Anchor<CGRect>], proxy: GeometryProxy) -> some View {
        if let hubAnchor = anchors["hub"] {
            let hub = proxy[hubAnchor]
            let inbound = viewModel.contributorCalendarKeys.compactMap { anchors["in:\($0)"].map { proxy[$0] } }
            let outbound = viewModel.recipientCalendarKeys.compactMap { anchors["out:\($0)"].map { proxy[$0] } }
            ZStack {
                ForEach(Array(inbound.enumerated()), id: \.offset) { _, row in
                    Self.curve(from: CGPoint(x: row.maxX, y: row.midY), to: CGPoint(x: hub.minX, y: hub.midY))
                        .stroke(Self.fanInColor.opacity(0.55), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                }
                ForEach(Array(outbound.enumerated()), id: \.offset) { _, row in
                    Self.curve(from: CGPoint(x: hub.maxX, y: hub.midY), to: CGPoint(x: row.minX, y: row.midY))
                        .stroke(Self.fanOutColor.opacity(0.6), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                }
            }
        }
    }

    /// A horizontal S-curve between two points.
    static func curve(from start: CGPoint, to end: CGPoint) -> Path {
        var path = Path()
        path.move(to: start)
        let pull = max(28, abs(end.x - start.x) * 0.55)
        path.addCurve(
            to: end,
            control1: CGPoint(x: start.x + pull, y: start.y),
            control2: CGPoint(x: end.x - pull, y: end.y)
        )
        return path
    }
}

/// Bounds of each calendar row ("in:<key>", "out:<key>") and of the consolidated card ("hub").
private struct FlowAnchorKey: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]

    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

/// The tallest column header's height.
private struct HeaderHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
