import DictionaryKit
import Foundation
import Observation
import PrivacyKit

public struct HistoryCorrection: Codable, Hashable, Sendable {
    public let matchedText: String
    public let replacement: String
    public let label: String

    init(_ hit: CorrectionHit) {
        matchedText = hit.matchedText
        replacement = hit.replacement
        switch hit.source {
        case .vocabulary(let term):
            label = "Vocabulary: \(term)"
        case .pair(let from, let to):
            label = "Dictionary: \(from) \u{2192} \(to)"
        }
    }
}

/// A persisted description of one change made between the raw and delivered text.
///
/// `kind` intentionally remains a string so newer refinement rules can be read by
/// older versions of Pour without making this persistence model depend on RefineKit.
public struct HistoryRefinementChange: Codable, Hashable, Sendable {
    public static let fillerRemovalKind = "fillerRemoval"

    public let kind: String
    public let original: String
    public let replacement: String
    public let rule: String

    public init(kind: String, original: String, replacement: String, rule: String = "") {
        self.kind = kind
        self.original = original
        self.replacement = replacement
        self.rule = rule
    }
}

public struct HistoryQualityMetrics: Codable, Hashable, Sendable {
    public let totalEntries: Int
    public let refinedEntries: Int
    public let totalChanges: Int
    public let fillersRemoved: Int
    public let restoredEntries: Int

    public var acceptedRefinedEntries: Int { max(0, refinedEntries - restoredEntries) }
    public var acceptanceRate: Double {
        guard refinedEntries > 0 else { return 0 }
        return Double(acceptedRefinedEntries) / Double(refinedEntries)
    }

    public init(
        totalEntries: Int,
        refinedEntries: Int,
        totalChanges: Int,
        fillersRemoved: Int,
        restoredEntries: Int
    ) {
        self.totalEntries = totalEntries
        self.refinedEntries = refinedEntries
        self.totalChanges = totalChanges
        self.fillersRemoved = fillersRemoved
        self.restoredEntries = restoredEntries
    }
}

public struct HistoryEntry: Identifiable, Codable, Sendable {
    public let id: UUID
    public let date: Date
    public let text: String
    public let appName: String?
    public let strategy: String
    public let elapsedMS: Int
    public let corrections: [HistoryCorrection]
    public let rawText: String
    public let refinementChanges: [HistoryRefinementChange]
    public let detectedCommands: [String]
    public let isRestored: Bool

    public init(
        id: UUID = UUID(),
        date: Date = Date(),
        text: String,
        appName: String?,
        strategy: String,
        elapsedMS: Int,
        corrections: [HistoryCorrection],
        rawText: String? = nil,
        refinementChanges: [HistoryRefinementChange] = [],
        detectedCommands: [String] = [],
        isRestored: Bool = false
    ) {
        self.id = id
        self.date = date
        self.text = text
        self.appName = appName
        self.strategy = strategy
        self.elapsedMS = elapsedMS
        self.corrections = corrections
        self.rawText = rawText ?? text
        self.refinementChanges = refinementChanges
        self.detectedCommands = detectedCommands
        self.isRestored = isRestored
    }

    private enum CodingKeys: String, CodingKey {
        case id, date, text, appName, strategy, elapsedMS, corrections
        case rawText, refinementChanges, detectedCommands, isRestored
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        date = try values.decode(Date.self, forKey: .date)
        text = try values.decode(String.self, forKey: .text)
        appName = try values.decodeIfPresent(String.self, forKey: .appName)
        strategy = try values.decode(String.self, forKey: .strategy)
        elapsedMS = try values.decode(Int.self, forKey: .elapsedMS)
        corrections = try values.decodeIfPresent([HistoryCorrection].self, forKey: .corrections) ?? []
        rawText = try values.decodeIfPresent(String.self, forKey: .rawText) ?? text
        refinementChanges = try values.decodeIfPresent([HistoryRefinementChange].self, forKey: .refinementChanges) ?? []
        detectedCommands = try values.decodeIfPresent([String].self, forKey: .detectedCommands) ?? []
        isRestored = try values.decodeIfPresent(Bool.self, forKey: .isRestored) ?? false
    }
}

/// A rolling five-day local transcription history with an explicit privacy off switch.
@MainActor
@Observable
public final class HistoryStore {
    public private(set) var entries: [HistoryEntry] = []
    public private(set) var isEnabled: Bool

    private let fileURL: URL
    private static let retention: TimeInterval = 5 * 24 * 60 * 60

    public init(fileURL: URL? = nil, enabled: Bool = true) {
        isEnabled = enabled
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Pour", isDirectory: true)
            try? SecureLocalStorage.prepareDirectory(support)
            self.fileURL = support.appendingPathComponent("history.json")
        }
        try? SecureLocalStorage.protectFile(self.fileURL)
        load()
        prune()
    }

    @discardableResult
    public func record(
        text: String,
        appName: String?,
        strategy: String,
        elapsedMS: Int,
        hits: [CorrectionHit],
        rawText: String? = nil,
        refinementChanges: [HistoryRefinementChange] = [],
        detectedCommands: [String] = []
    ) -> HistoryEntry? {
        guard isEnabled else { return nil }
        let entry = HistoryEntry(
            text: text,
            appName: appName,
            strategy: strategy,
            elapsedMS: elapsedMS,
            corrections: hits.map(HistoryCorrection.init),
            rawText: rawText,
            refinementChanges: refinementChanges,
            detectedCommands: detectedCommands
        )
        entries.insert(entry, at: 0)
        prune()
        save()
        return entry
    }

    public func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
    }

    public func clear() {
        entries.removeAll()
        try? FileManager.default.removeItem(at: fileURL)
    }

    public func delete(_ entry: HistoryEntry) {
        entries.removeAll { $0.id == entry.id }
        save()
    }

    /// Records that the delivered refinement was rejected and its raw text restored.
    @discardableResult
    public func markRestored(id: UUID) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == id }), !entries[index].isRestored else {
            return false
        }
        let entry = entries[index]
        entries[index] = HistoryEntry(
            id: entry.id,
            date: entry.date,
            text: entry.text,
            appName: entry.appName,
            strategy: entry.strategy,
            elapsedMS: entry.elapsedMS,
            corrections: entry.corrections,
            rawText: entry.rawText,
            refinementChanges: entry.refinementChanges,
            detectedCommands: entry.detectedCommands,
            isRestored: true
        )
        save()
        return true
    }

    public var qualityMetrics: HistoryQualityMetrics {
        let refined = entries.filter { !$0.refinementChanges.isEmpty }
        return HistoryQualityMetrics(
            totalEntries: entries.count,
            refinedEntries: refined.count,
            totalChanges: entries.reduce(0) { $0 + $1.refinementChanges.count },
            fillersRemoved: entries.reduce(0) { total, entry in
                total + entry.refinementChanges.filter { $0.kind == HistoryRefinementChange.fillerRemovalKind }.count
            },
            restoredEntries: refined.filter(\.isRestored).count
        )
    }

    public func search(_ query: String) -> [HistoryEntry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return entries }
        return entries.filter { $0.text.lowercased().contains(q) || ($0.appName?.lowercased().contains(q) ?? false) }
    }

    private func prune() {
        let cutoff = Date().addingTimeInterval(-Self.retention)
        entries.removeAll { $0.date < cutoff }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data)
        else { return }
        entries = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        do {
            try data.write(to: fileURL, options: .atomic)
            try SecureLocalStorage.protectFile(fileURL)
        } catch {
            // History is best-effort; failed persistence must never interrupt dictation.
        }
    }
}
