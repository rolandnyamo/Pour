import AppKit
import Charts
import DesignKit
import HistoryKit
import SwiftUI

struct StatsView: View {
    private enum Section: String, CaseIterable, Identifiable {
        case summary = "Summary"
        case apps = "Apps"

        var id: Self { self }
    }

    @Environment(AppModel.self) private var model
    @State private var section: Section = .summary

    var body: some View {
        VStack(spacing: 0) {
            Picker("Stats section", selection: $section) {
                ForEach(Section.allCases) { section in
                    Text(section.rawValue).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)
            .padding(.top, PourSpace.md)
            .padding(.bottom, PourSpace.xs)

            switch section {
            case .summary:
                summaryView
            case .apps:
                AppsStatsView(store: model.usageStats)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Stats")
    }

    /// The original Stats view stays intact as the default Summary workflow.
    private var summaryView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PourSpace.xl) {
                Text("How much dictating has actually saved you — estimated, not measured.")
                    .font(PourFont.callout())
                    .foregroundStyle(PourColor.textMuted)

                VStack(spacing: PourSpace.md) {
                    statCard(title: "Last 7 Days", totals: model.usageStats.last7Days)
                    statCard(title: "Last 30 Days", totals: model.usageStats.last30Days)
                    statCard(title: "All Time", totals: model.usageStats.allTime)
                }

                Text("Time saved assumes an average typing speed of \(Int(assumedTypingWPM)) words per minute against the words you actually dictated. It's an estimate to give you a sense of scale, not a measurement of how long typing would have taken.")
                    .font(PourFont.callout())
                    .foregroundStyle(PourColor.textDim)
            }
            .padding(PourSpace.lg)
            .frame(maxWidth: 560, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
    }

    private func statCard(title: String, totals: UsageStatsStore.Totals) -> some View {
        VStack(alignment: .leading, spacing: PourSpace.md) {
            Text(title.uppercased())
                .font(PourFont.caption())
                .foregroundStyle(PourColor.textDim)

            HStack(alignment: .lastTextBaseline, spacing: PourSpace.xxl) {
                statBlock(
                    value: totals.words.formatted(),
                    label: totals.words == 1 ? "word dictated" : "words dictated",
                    color: PourColor.text
                )
                statBlock(
                    value: totals.dictations.formatted(),
                    label: totals.dictations == 1 ? "dictation" : "dictations",
                    color: PourColor.text
                )
                statBlock(
                    value: formattedDuration(minutes: totals.estimatedMinutesSaved),
                    label: "estimated saved",
                    color: PourColor.success
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .pourCard(padding: PourSpace.lg)
    }

    private func statBlock(value: String, label: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(PourFont.display(26))
                .foregroundStyle(color)
            Text(label)
                .font(PourFont.callout())
                .foregroundStyle(PourColor.textMuted)
        }
    }
}

private struct AppsStatsView: View {
    private enum Range: String, CaseIterable, Identifiable {
        case sevenDays = "7 Days"
        case thirtyDays = "30 Days"
        case allTime = "All Time"

        var id: Self { self }

        var days: Int? {
            switch self {
            case .sevenDays: 7
            case .thirtyDays: 30
            case .allTime: nil
            }
        }
    }

    let store: UsageStatsStore
    @State private var range: Range = .thirtyDays
    @State private var hoveredAppID: String?

    private var apps: [AppUsageTotals] {
        store.appTotals(lastDays: range.days)
    }

    private var totalWords: Int {
        apps.reduce(0) { $0 + $1.words }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PourSpace.xl) {
                HStack(alignment: .center) {
                    Text("Where you dictate most")
                        .font(PourFont.callout())
                        .foregroundStyle(PourColor.textMuted)

                    Spacer()

                    Picker("Date range", selection: $range) {
                        ForEach(Range.allCases) { range in
                            Text(range.rawValue).tag(range)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 250)
                }

                if apps.isEmpty {
                    emptyState
                } else {
                    chartCard
                }

                Text("App usage is based on words dictated. It stays on this Mac with the rest of your stats.")
                    .font(PourFont.callout())
                    .foregroundStyle(PourColor.textDim)
            }
            .padding(PourSpace.lg)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
    }

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: PourSpace.md) {
            Text("WORDS BY APP")
                .font(PourFont.caption())
                .foregroundStyle(PourColor.textDim)

            ScrollView(.horizontal, showsIndicators: apps.count > 7) {
                Chart(apps) { app in
                    BarMark(
                        x: .value("App", app.id),
                        y: .value("Words", app.words)
                    )
                    .foregroundStyle(hoveredAppID == app.id ? PourColor.amber : PourColor.blue500)
                    .cornerRadius(PourRadius.sm)
                    .opacity(hoveredAppID == nil || hoveredAppID == app.id ? 1 : 0.5)
                    .annotation(position: .top, spacing: PourSpace.xxs) {
                        if hoveredAppID == app.id {
                            Text(percentage(for: app).formatted(.percent.precision(.fractionLength(0))))
                                .font(PourFont.monoMedium(11))
                                .foregroundStyle(PourColor.text)
                                .padding(.horizontal, PourSpace.xs)
                                .padding(.vertical, PourSpace.xxs)
                                .background(PourColor.surfacePanel2)
                                .clipShape(RoundedRectangle(cornerRadius: PourRadius.sm, style: .continuous))
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: apps.map(\.id)) { value in
                        AxisValueLabel(centered: true) {
                            if let appID = value.as(String.self),
                               let app = apps.first(where: { $0.id == appID }) {
                                VStack(spacing: PourSpace.xxs) {
                                    AppIcon(app: app)
                                    Text(app.appName)
                                        .font(PourFont.caption(10))
                                        .foregroundStyle(PourColor.textMuted)
                                        .lineLimit(1)
                                        .frame(width: 68)
                                }
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine()
                            .foregroundStyle(PourColor.borderHairline)
                        AxisValueLabel {
                            if let words = value.as(Int.self) {
                                Text(words.formatted(.number.notation(.compactName)))
                                    .font(PourFont.mono(10))
                                    .foregroundStyle(PourColor.textDim)
                            }
                        }
                    }
                }
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        Rectangle()
                            .fill(.clear)
                            .contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let location):
                                    guard let plotFrame = proxy.plotFrame else {
                                        hoveredAppID = nil
                                        return
                                    }
                                    let frame = geometry[plotFrame]
                                    guard frame.contains(location) else {
                                        hoveredAppID = nil
                                        return
                                    }
                                    hoveredAppID = proxy.value(atX: location.x - frame.origin.x, as: String.self)
                                case .ended:
                                    hoveredAppID = nil
                                }
                            }
                    }
                }
                .frame(width: max(500, CGFloat(apps.count) * 82), height: 290)
                .padding(.top, PourSpace.lg)
                .animation(PourMotion.animation(.easeOut(duration: PourMotion.fast)), value: hoveredAppID)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .pourCard(padding: PourSpace.lg)
    }

    private var emptyState: some View {
        VStack(spacing: PourSpace.sm) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(PourColor.amber)
            Text("No app stats yet")
                .font(PourFont.display(22))
                .foregroundStyle(PourColor.text)
            Text("Your apps will appear here after your next dictation.")
                .font(PourFont.callout())
                .foregroundStyle(PourColor.textMuted)
        }
        .frame(maxWidth: .infinity, minHeight: 260)
        .pourCard(padding: PourSpace.lg)
    }

    private func percentage(for app: AppUsageTotals) -> Double {
        guard totalWords > 0 else { return 0 }
        return Double(app.words) / Double(totalWords)
    }
}

private struct AppIcon: View {
    let app: AppUsageTotals

    var body: some View {
        Group {
            if let image = image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
            } else {
                Image(systemName: "app.fill")
                    .resizable()
                    .scaledToFit()
                    .padding(4)
                    .foregroundStyle(PourColor.textMuted)
            }
        }
        .frame(width: 24, height: 24)
    }

    private var image: NSImage? {
        if let bundleIdentifier = app.bundleIdentifier,
           let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return NSWorkspace.shared.icon(forFile: applicationURL.path)
        }

        guard let application = InstalledApplicationResolver.application(named: app.appName) else { return nil }
        return NSWorkspace.shared.icon(forFile: application.url.path)
    }
}

private func formattedDuration(minutes: Double) -> String {
    let totalMinutes = Int(minutes.rounded())
    guard totalMinutes >= 1 else { return "< 1m" }
    let hours = totalMinutes / 60
    let mins = totalMinutes % 60
    if hours == 0 { return "\(mins)m" }
    return "\(hours)h \(mins)m"
}
