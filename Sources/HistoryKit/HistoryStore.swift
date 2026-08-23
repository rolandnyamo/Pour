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

public struct HistoryEntry: Identifiable, Codable, Sendable {
    public let id: UUID
    public let date: Date
    public let text: String
    public let appName: String?
    public let strategy: String
    public let elapsedMS: Int
    public let corrections: [HistoryCorrection]

    public init(
        id: UUID = UUID(),
        date: Date = Date(),
        text: String,
        appName: String?,
        strategy: String,
        elapsedMS: Int,
        corrections: [HistoryCorrection]
    ) {
        self.id = id
        self.date = date
        self.text = text
        self.appName = appName
        self.strategy = strategy
        self.elapsedMS = elapsedMS
        self.corrections = corrections
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
    public func record(text: String, appName: String?, strategy: String, elapsedMS: Int, hits: [CorrectionHit]) -> HistoryEntry? {
        guard isEnabled else { return nil }
        let entry = HistoryEntry(
            text: text,
            appName: appName,
            strategy: strategy,
            elapsedMS: elapsedMS,
            corrections: hits.map(HistoryCorrection.init)
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
