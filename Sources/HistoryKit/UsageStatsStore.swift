import Foundation
import Observation
import PrivacyKit

/// One day's tally. Kept indefinitely (unlike `HistoryEntry`, which is pruned after
/// five days) — a "this month" stat that quietly resets itself because the
/// transcripts it was derived from expired would be worse than useless.
public struct DailyUsage: Codable, Sendable {
    public let day: Date // start-of-day, local calendar
    public var wordCount: Int
    public var dictationCount: Int
    public var apps: [DailyAppUsage]

    public init(day: Date, wordCount: Int, dictationCount: Int, apps: [DailyAppUsage] = []) {
        self.day = day
        self.wordCount = wordCount
        self.dictationCount = dictationCount
        self.apps = apps
    }

    private enum CodingKeys: String, CodingKey {
        case day, wordCount, dictationCount, apps
    }

    /// `apps` was added after aggregate stats shipped. Missing app data decodes as
    /// an empty breakdown so existing totals survive the upgrade unchanged.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        day = try values.decode(Date.self, forKey: .day)
        wordCount = try values.decode(Int.self, forKey: .wordCount)
        dictationCount = try values.decode(Int.self, forKey: .dictationCount)
        apps = try values.decodeIfPresent([DailyAppUsage].self, forKey: .apps) ?? []
    }
}

/// One app's contribution to a day's aggregate. The bundle identifier is the stable
/// identity when macOS provides one; the derived `id` also supports the occasional
/// Accessibility target that exposes only a display name.
public struct DailyAppUsage: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public var bundleIdentifier: String?
    public var appName: String
    public var wordCount: Int
    public var dictationCount: Int

    public init(
        id: String,
        bundleIdentifier: String?,
        appName: String,
        wordCount: Int,
        dictationCount: Int
    ) {
        self.id = id
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.wordCount = wordCount
        self.dictationCount = dictationCount
    }
}

/// A range-wide total for one app, ready for the Stats UI to sort and chart.
public struct AppUsageTotals: Identifiable, Sendable, Equatable {
    public let id: String
    public let bundleIdentifier: String?
    public let appName: String
    public let words: Int
    public let dictations: Int

    public var estimatedMinutesSaved: Double {
        Double(words) / assumedTypingWPM
    }
}

/// Assumed average typing speed, for the "time saved" estimate. There's no way to
/// measure the counterfactual (how long typing this would have actually taken), so
/// this is deliberately a round, commonly-cited number — the UI should always present
/// the result as an estimate, not a measurement. Top-level (not a member of
/// `UsageStatsStore`) so `Totals.estimatedMinutesSaved` can read it without needing
/// `@MainActor` isolation itself.
public let assumedTypingWPM: Double = 40

/// Rolling usage totals — words dictated, dictation count, and an estimated time
/// saved versus typing. Independent of `HistoryStore`'s retention window and
/// independent of whether History is even enabled, since these are just counts, not
/// the transcript text itself.
@MainActor
@Observable
public final class UsageStatsStore {

    public private(set) var daily: [DailyUsage] = []

    private let fileURL: URL

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Pour", isDirectory: true)
            try? SecureLocalStorage.prepareDirectory(support)
            self.fileURL = support.appendingPathComponent("usage-stats.json")
        }
        try? SecureLocalStorage.protectFile(self.fileURL)
        load()
    }

    /// Called once per delivered dictation, regardless of whether History is enabled.
    public func record(
        wordCount: Int,
        appBundleIdentifier: String? = nil,
        appName: String? = nil,
        at date: Date = Date()
    ) {
        guard wordCount > 0 else { return }
        let today = Calendar.current.startOfDay(for: date)
        let identity = Self.appIdentity(bundleIdentifier: appBundleIdentifier, appName: appName)

        if let index = daily.firstIndex(where: { $0.day == today }) {
            daily[index].wordCount += wordCount
            daily[index].dictationCount += 1
            recordApp(identity, wordCount: wordCount, in: &daily[index])
        } else {
            var usage = DailyUsage(day: today, wordCount: wordCount, dictationCount: 1)
            recordApp(identity, wordCount: wordCount, in: &usage)
            daily.append(usage)
        }
        save()
    }

    public struct Totals {
        public let words: Int
        public let dictations: Int

        /// Minutes an average typist would need for this many words, at
        /// `assumedTypingWPM` — the headline "time saved" figure.
        public var estimatedMinutesSaved: Double {
            Double(words) / assumedTypingWPM
        }
    }

    public func totals(lastDays: Int?) -> Totals {
        let relevant: [DailyUsage]
        if let lastDays {
            let cutoff = Calendar.current.date(byAdding: .day, value: -(lastDays - 1), to: Calendar.current.startOfDay(for: Date()))!
            relevant = daily.filter { $0.day >= cutoff }
        } else {
            relevant = daily
        }
        return Totals(
            words: relevant.reduce(0) { $0 + $1.wordCount },
            dictations: relevant.reduce(0) { $0 + $1.dictationCount }
        )
    }

    public var last7Days: Totals { totals(lastDays: 7) }
    public var last30Days: Totals { totals(lastDays: 30) }
    public var allTime: Totals { totals(lastDays: nil) }

    /// Fills app breakdowns for legacy aggregate-only days using transcript history
    /// that is still available locally. Existing app breakdowns are never touched,
    /// so this is safe to call on every launch without double-counting.
    @discardableResult
    public func backfillAppUsage(
        from history: [HistoryEntry],
        bundleIdentifierForAppName: (String) -> String? = { _ in nil }
    ) -> Int {
        let calendar = Calendar.current
        let entriesByDay = Dictionary(grouping: history) { calendar.startOfDay(for: $0.date) }
        var migratedDays = 0

        for dayIndex in daily.indices where daily[dayIndex].apps.isEmpty {
            let usageDay = daily[dayIndex].day
            let entries = entriesByDay[usageDay] ?? []

            var apps: [DailyAppUsage] = []
            var migratedWords = 0
            var migratedDictations = 0

            for entry in entries {
                let wordCount = entry.text.split(whereSeparator: \.isWhitespace).count
                guard wordCount > 0 else { continue }

                let bundleIdentifier = entry.appName.flatMap(bundleIdentifierForAppName)
                let identity = Self.appIdentity(bundleIdentifier: bundleIdentifier, appName: entry.appName)
                if let index = apps.firstIndex(where: { $0.id == identity.id }) {
                    apps[index].wordCount += wordCount
                    apps[index].dictationCount += 1
                } else {
                    apps.append(DailyAppUsage(
                        id: identity.id,
                        bundleIdentifier: identity.bundleIdentifier,
                        appName: identity.appName,
                        wordCount: wordCount,
                        dictationCount: 1
                    ))
                }
                migratedWords += wordCount
                migratedDictations += 1
            }

            // A deleted transcript or history-disabled period can leave only part of
            // a day's aggregate attributable. Keep that remainder visible without
            // guessing which app it belonged to.
            guard !apps.isEmpty,
                  migratedWords <= daily[dayIndex].wordCount,
                  migratedDictations <= daily[dayIndex].dictationCount
            else {
                let unknown = Self.appIdentity(bundleIdentifier: nil, appName: nil)
                daily[dayIndex].apps = [DailyAppUsage(
                    id: unknown.id,
                    bundleIdentifier: nil,
                    appName: unknown.appName,
                    wordCount: daily[dayIndex].wordCount,
                    dictationCount: daily[dayIndex].dictationCount
                )]
                migratedDays += 1
                continue
            }

            let remainingWords = daily[dayIndex].wordCount - migratedWords
            let remainingDictations = daily[dayIndex].dictationCount - migratedDictations
            if remainingWords > 0 || remainingDictations > 0 {
                let unknown = Self.appIdentity(bundleIdentifier: nil, appName: nil)
                apps.append(DailyAppUsage(
                    id: unknown.id,
                    bundleIdentifier: nil,
                    appName: unknown.appName,
                    wordCount: remainingWords,
                    dictationCount: remainingDictations
                ))
            }

            daily[dayIndex].apps = apps
            migratedDays += 1
        }

        if migratedDays > 0 { save() }
        return migratedDays
    }

    public func appTotals(lastDays: Int?) -> [AppUsageTotals] {
        let relevant = entries(lastDays: lastDays)
        var totals: [String: AppUsageTotals] = [:]

        // Newest name wins for a bundle identifier, so a renamed app is labelled the
        // way macOS identifies it now while all of its earlier usage remains grouped.
        for day in relevant.sorted(by: { $0.day < $1.day }) {
            for app in day.apps {
                let current = totals[app.id]
                totals[app.id] = AppUsageTotals(
                    id: app.id,
                    bundleIdentifier: app.bundleIdentifier ?? current?.bundleIdentifier,
                    appName: app.appName,
                    words: (current?.words ?? 0) + app.wordCount,
                    dictations: (current?.dictations ?? 0) + app.dictationCount
                )
            }
        }

        return totals.values.sorted {
            if $0.words != $1.words { return $0.words > $1.words }
            return $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending
        }
    }

    private func entries(lastDays: Int?) -> [DailyUsage] {
        guard let lastDays else { return daily }
        let today = Calendar.current.startOfDay(for: Date())
        let cutoff = Calendar.current.date(byAdding: .day, value: -(lastDays - 1), to: today)!
        return daily.filter { $0.day >= cutoff }
    }

    private struct AppIdentity {
        let id: String
        let bundleIdentifier: String?
        let appName: String
    }

    private static func appIdentity(bundleIdentifier: String?, appName: String?) -> AppIdentity {
        let bundle = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = appName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = name.flatMap { $0.isEmpty ? nil : $0 } ?? "Unknown App"

        if let bundle, !bundle.isEmpty {
            return AppIdentity(id: "bundle:\(bundle)", bundleIdentifier: bundle, appName: displayName)
        }

        return AppIdentity(
            id: "name:\(displayName.lowercased())",
            bundleIdentifier: nil,
            appName: displayName
        )
    }

    private func recordApp(_ identity: AppIdentity, wordCount: Int, in day: inout DailyUsage) {
        if let index = day.apps.firstIndex(where: { $0.id == identity.id }) {
            day.apps[index].appName = identity.appName
            day.apps[index].bundleIdentifier = identity.bundleIdentifier ?? day.apps[index].bundleIdentifier
            day.apps[index].wordCount += wordCount
            day.apps[index].dictationCount += 1
        } else {
            day.apps.append(DailyAppUsage(
                id: identity.id,
                bundleIdentifier: identity.bundleIdentifier,
                appName: identity.appName,
                wordCount: wordCount,
                dictationCount: 1
            ))
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([DailyUsage].self, from: data)
        else { return }
        daily = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(daily) else { return }
        do {
            try data.write(to: fileURL, options: .atomic)
            try SecureLocalStorage.protectFile(fileURL)
        } catch {
            // Best-effort, same as HistoryStore — failed persistence must never
            // interrupt dictation.
        }
    }
}
