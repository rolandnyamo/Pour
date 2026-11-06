import Foundation
import HistoryKit

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

@main
struct HistoryMigrationChecks {
    @MainActor
    static func main() throws {
        // Pass 1: JSON written before refinement fields existed still decodes.
        let legacyID = UUID()
        let legacyObject: [[String: Any]] = [[
            "id": legacyID.uuidString,
            "date": Date().timeIntervalSinceReferenceDate,
            "text": "legacy transcript",
            "appName": "Notes",
            "strategy": "accessibility",
            "elapsedMS": 42,
            "corrections": []
        ]]
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let legacyEntries = try JSONDecoder().decode([HistoryEntry].self, from: legacyData)
        require(legacyEntries.count == 1, "legacy entry count")
        require(legacyEntries[0].rawText == "legacy transcript", "legacy raw text fallback")
        require(legacyEntries[0].refinementChanges.isEmpty, "legacy changes default")
        require(legacyEntries[0].detectedCommands.isEmpty, "legacy commands default")
        require(!legacyEntries[0].isRestored, "legacy restore default")

        // Pass 2: recording retains raw/refined metadata and commands.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PourHistoryMigration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("history.json")
        let store = HistoryStore(fileURL: fileURL)
        let changes = [
            HistoryRefinementChange(kind: HistoryRefinementChange.fillerRemovalKind, original: "um", replacement: "", rule: "conservative filler"),
            HistoryRefinementChange(kind: "repetitionRemoval", original: "the the", replacement: "the", rule: "adjacent repetition")
        ]
        let recorded = store.record(
            text: "Send the report.",
            appName: "Mail",
            strategy: "accessibility",
            elapsedMS: 120,
            hits: [],
            rawText: "um send the the report",
            refinementChanges: changes,
            detectedCommands: ["period"]
        )
        require(recorded?.rawText == "um send the the report", "recorded raw text")
        require(recorded?.refinementChanges == changes, "recorded changes")
        require(recorded?.detectedCommands == ["period"], "recorded commands")

        // Pass 3: quality aggregates distinguish changes, fillers, and acceptance.
        var metrics = store.qualityMetrics
        require(metrics.totalEntries == 1, "quality total")
        require(metrics.refinedEntries == 1, "quality refined")
        require(metrics.totalChanges == 2, "quality changes")
        require(metrics.fillersRemoved == 1, "quality fillers")
        require(metrics.restoredEntries == 0, "quality restores before restore")
        require(metrics.acceptedRefinedEntries == 1 && metrics.acceptanceRate == 1, "quality acceptance proxy")

        // Pass 4: restore is idempotent and persists across a reload.
        let id = try recorded.map { $0.id }.unwrap(or: "record did not return an entry")
        require(store.markRestored(id: id), "first restore")
        require(!store.markRestored(id: id), "duplicate restore")
        metrics = store.qualityMetrics
        require(metrics.restoredEntries == 1, "quality restore count")
        require(metrics.acceptedRefinedEntries == 0 && metrics.acceptanceRate == 0, "quality rejected refinement")
        let reloaded = HistoryStore(fileURL: fileURL)
        require(reloaded.entries.first?.isRestored == true, "persisted restore")

        print("ALL HISTORY MIGRATION CHECKS PASSED")
    }
}

private extension Optional {
    func unwrap(or message: String) throws -> Wrapped {
        guard let value = self else {
            throw NSError(domain: "HistoryMigrationChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        return value
    }
}
