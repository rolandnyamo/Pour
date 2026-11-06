import Foundation

public enum CleanupLevel: String, Codable, Sendable, CaseIterable {
    case off, conservative, balanced, aggressive
}

public enum AccuracyMode: String, Codable, Sendable, CaseIterable {
    case fast, accurate, smartLocal
}

public struct RefinementConfiguration: Codable, Hashable, Sendable {
    public var cleanupLevel: CleanupLevel
    public var fillerRemoval: Bool
    public var repetitionCleanup: Bool
    public var falseStartCleanup: Bool
    public var spokenPunctuation: Bool
    public var listFormatting: Bool

    public init(
        cleanupLevel: CleanupLevel = .conservative,
        fillerRemoval: Bool = true,
        repetitionCleanup: Bool = true,
        falseStartCleanup: Bool = true,
        spokenPunctuation: Bool = true,
        listFormatting: Bool = true
    ) {
        self.cleanupLevel = cleanupLevel
        self.fillerRemoval = fillerRemoval
        self.repetitionCleanup = repetitionCleanup
        self.falseStartCleanup = falseStartCleanup
        self.spokenPunctuation = spokenPunctuation
        self.listFormatting = listFormatting
    }

    public static let disabled = RefinementConfiguration(cleanupLevel: .off)
}

public enum RefinementChangeKind: String, Codable, Sendable {
    case normalization
    case fillerRemoval
    case repetitionRemoval
    case falseStartRemoval
    case spokenPunctuation
    case voiceCommand
    case listFormatting
    case contextualCleanup
}

public struct RefinementChange: Codable, Hashable, Sendable {
    public let kind: RefinementChangeKind
    public let original: String
    public let replacement: String
    public let rule: String

    public init(kind: RefinementChangeKind, original: String, replacement: String, rule: String) {
        self.kind = kind
        self.original = original
        self.replacement = replacement
        self.rule = rule
    }
}

public enum VoiceCommand: String, Codable, Sendable, CaseIterable {
    case newLine
    case newParagraph
    case bulletPoint
    case scratchThat
}

public struct RefinementCounters: Codable, Hashable, Sendable {
    public var fillersRemoved = 0
    public var repetitionsRemoved = 0
    public var falseStartsRemoved = 0
    public var commandsApplied = 0
    public var punctuationMarksInserted = 0
    public var listsFormatted = 0

    public init() {}
}

public struct RefinementResult: Codable, Hashable, Sendable {
    public let rawText: String
    public let refinedText: String
    public let changes: [RefinementChange]
    public let detectedCommands: [VoiceCommand]
    public let counters: RefinementCounters

    public init(rawText: String, refinedText: String, changes: [RefinementChange], detectedCommands: [VoiceCommand], counters: RefinementCounters) {
        self.rawText = rawText
        self.refinedText = refinedText
        self.changes = changes
        self.detectedCommands = detectedCommands
        self.counters = counters
    }
}

/// Extension point for a future on-device provider. The built-in refiner is fully
/// functional and does not require an implementation of this protocol.
public protocol TranscriptRefiner: Sendable {
    func refine(_ text: String, mode: AccuracyMode, configuration: RefinementConfiguration) async throws -> RefinementResult
}
