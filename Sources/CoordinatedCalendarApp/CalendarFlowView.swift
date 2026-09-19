import CoordinatedCalendarCore
import SwiftUI

/// Fan-in and fan-out on one page: contributors on the left, the consolidated calendar in the middle and
/// recipients on the right, joined by curves from each checked contributor into the consolidated calendar
/// and from it out to each checked recipient.
struct CalendarFlowView: View {
    @ObservedObject var viewModel: BridgeViewModel
    /// Height of the taller column header, so the consolidated card centers on the calendar rows alone.
    @State private var headerHeight: CGFloat = 0
    /// Bottom of the busy-block options and height of the columns, to add scroll room where they overhang.
    @State private var optionsBottom: CGFloat = 0
    @State private var columnsHeight: CGFloat = 0

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
            .coordinateSpace(name: "flow")
            .background(GeometryReader { proxy in
                Color.clear.preference(key: ColumnsHeightKey.self, value: proxy.size.height)
            })
            // Scroll room for the busy-block options where they hang below the columns' end.
            .padding(.bottom, max(0, optionsBottom - columnsHeight))
            .padding(.vertical, 6)
            .onPreferenceChange(HeaderHeightKey.self) { headerHeight = $0 }
            .onPreferenceChange(OptionsOverhangKey.self) { optionsBottom = $0 }
            .onPreferenceChange(ColumnsHeightKey.self) { columnsHeight = $0 }
            .backgroundPreferenceValue(FlowAnchorKey.self) { anchors in
                GeometryReader { proxy in
                    flowLines(anchors: anchors, proxy: proxy)
                }
                .allowsHitTesting(false)
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
                calendarRow(
                    calendar,
                    selected: viewModel.contributorCalendarKeys.contains(calendar.stableKey),
                    color: Self.fanInColor,
                    anchorID: "in:\(calendar.stableKey)",
                    set: { viewModel.setContributor(calendar.stableKey, enabled: $0) }
                )
            }
        }
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
                Text("Keeps full, readable details of every gathered event. Create it in the Calendar app (File > New Calendar), in an account where that is acceptable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Label("\(viewModel.contributorCalendarKeys.count) in", systemImage: "arrow.right")
                        .foregroundStyle(Self.fanInColor)
                    Label("\(viewModel.recipientCalendarKeys.count) out", systemImage: "arrow.right")
                        .foregroundStyle(Self.fanOutColor)
                }
                .font(.caption.weight(.semibold))
            }
            .padding(12)
            .background(.background, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 1.5))
            .anchorPreference(key: FlowAnchorKey.self, value: .bounds) { ["hub": $0] }
            // The fan-out options hang 12 points below the card without affecting layout, so the card alone
            // is centered between the tops and bottoms of the calendar lists.
            .overlay(alignment: .bottom) {
                busyBlockOptions
                    .alignmentGuide(.bottom) { dimensions in dimensions[.top] - 12 }
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: OptionsOverhangKey.self, value: proxy.frame(in: .named("flow")).maxY)
                    })
            }
            Spacer(minLength: 0)
        }
    }

    private var recipientsColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            columnHeader(
                "Fan-Out",
                systemImage: "arrow.up.left.and.arrow.down.right",
                color: Self.fanOutColor,
                detail: "Checked calendars receive a busy block for every consolidated event, except those that came from them. Blocks carry only the busy block title (set in the middle), times, free/busy status and a hashed marker."
            )
            ForEach(viewModel.calendars.filter { $0.allowsContentModifications && $0.stableKey != viewModel.consolidatedCalendarKey }) { calendar in
                calendarRow(
                    calendar,
                    selected: viewModel.recipientCalendarKeys.contains(calendar.stableKey),
                    color: Self.fanOutColor,
                    anchorID: "out:\(calendar.stableKey)",
                    availability: calendar.stableKey,
                    set: { viewModel.setRecipient(calendar.stableKey, enabled: $0) }
                )
            }
        }
    }

    private var busyBlockOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Busy blocks", systemImage: "rectangle.badge.checkmark")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Self.fanOutColor)
            VStack(alignment: .leading, spacing: 4) {
                Text("Title")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField(FreeBusyCompliance.fanOutTitle, text: Binding(
                    get: { viewModel.fanOutTitle },
                    set: { viewModel.setFanOutTitle($0) }
                ))
                .textFieldStyle(.roundedBorder)
            }
            Toggle("Skip events marked Free", isOn: Binding(
                get: { viewModel.skipFreeEvents },
                set: { viewModel.setSkipFreeEvents($0) }
            ))
            Toggle("Skip meetings you declined", isOn: Binding(
                get: { viewModel.skipDeclinedEvents },
                set: { viewModel.setSkipDeclinedEvents($0) }
            ))
            Text("The title is the only text a block carries; changing it retitles existing blocks. Skipped events get no block, and existing blocks for them are removed.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(Self.fanOutColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private func columnHeader(_ title: String, systemImage: String, color: Color, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(color)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
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
        set: @escaping @MainActor (Bool) -> Void
    ) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Toggle(isOn: Binding(get: { selected }, set: set)) {
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
                Picker("Availability", selection: Binding(
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

/// Bottom edge of the busy-block options in the "flow" coordinate space.
private struct OptionsOverhangKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Height of the three columns, before any overhang room.
private struct ColumnsHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
