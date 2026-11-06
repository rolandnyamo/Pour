import Foundation

public struct LocalTranscriptRefiner: TranscriptRefiner, Sendable {
    public init() {}

    public func refine(_ text: String, mode: AccuracyMode = .accurate, configuration: RefinementConfiguration = .init()) async throws -> RefinementResult {
        refineSynchronously(text, mode: mode, configuration: configuration)
    }

    public func refineSynchronously(_ text: String, mode: AccuracyMode = .accurate, configuration: RefinementConfiguration = .init()) -> RefinementResult {
        var state = State(rawText: text)
        state.protectLiterals()

        if mode != .fast && configuration.cleanupLevel != .off {
            state.applyCommands()
            if configuration.spokenPunctuation { state.applySpokenPunctuation() }
            if configuration.fillerRemoval { state.removeFillers(level: configuration.cleanupLevel) }
            if configuration.repetitionCleanup { state.removeRepetitions(level: configuration.cleanupLevel) }
            if configuration.falseStartCleanup { state.removeFalseStarts(level: configuration.cleanupLevel, smart: mode == .smartLocal) }
            if configuration.listFormatting { state.formatLists() }
            if mode == .smartLocal { state.applyContextualCleanup() }
        }

        state.normalizeWhitespace()
        state.restoreLiterals()
        state.finishWhitespace()
        return state.result
    }
}

private struct State {
    let rawText: String
    var text: String
    var changes: [RefinementChange] = []
    var commands: [VoiceCommand] = []
    var counters = RefinementCounters()
    var literals: [String] = []

    init(rawText: String) {
        self.rawText = rawText
        self.text = rawText
    }

    var result: RefinementResult {
        RefinementResult(rawText: rawText, refinedText: text, changes: changes, detectedCommands: commands, counters: counters)
    }

    mutating func protectLiterals() {
        let regex = try! NSRegularExpression(pattern: "(?i)\\bliteral\\s+((?:new\\s+(?:line|paragraph)|bullet\\s+point|scratch\\s+that|comma|period|full\\s+stop|question\\s+mark|exclamation\\s+(?:mark|point)|semicolon|colon|um|uh|erm|ah))\\b")
        while let match = regex.firstMatch(in: text, range: fullRange), let captured = Range(match.range(at: 1), in: text), let whole = Range(match.range, in: text) {
            let value = String(text[captured])
            let token = "\u{E000}\(literals.count)\u{E001}"
            literals.append(value)
            text.replaceSubrange(whole, with: token)
        }
    }

    mutating func restoreLiterals() {
        for (index, value) in literals.enumerated() {
            text = text.replacingOccurrences(of: "\u{E000}\(index)\u{E001}", with: value)
        }
    }

    mutating func applyCommands() {
        let detector = try! NSRegularExpression(pattern: "(?i)\\b(new\\s+line|new\\s+paragraph|bullet\\s+point|scratch\\s+that)\\b")
        commands = detector.matches(in: text, range: fullRange).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            switch text[range].lowercased().replacingOccurrences(of: " ", with: "") {
            case "newline": return .newLine
            case "newparagraph": return .newParagraph
            case "bulletpoint": return .bulletPoint
            case "scratchthat": return .scratchThat
            default: return nil
            }
        }
        replaceCommand("new\\s+paragraph", with: "\n\n", command: .newParagraph)
        replaceCommand("new\\s+line", with: "\n", command: .newLine)
        replaceCommand("bullet\\s+point", with: "\n• ", command: .bulletPoint)

        let scratch = try! NSRegularExpression(pattern: "(?i)(?:^|(?<=[.!?\\n]))[^.!?\\n]*?\\bscratch\\s+that\\b[,.]?\\s*")
        while let match = scratch.firstMatch(in: text, range: fullRange), let range = Range(match.range, in: text) {
            let original = String(text[range])
            text.replaceSubrange(range, with: "")
            record(.voiceCommand, original, "", "scratch that")
            counters.commandsApplied += 1
        }
    }

    mutating func replaceCommand(_ pattern: String, with replacement: String, command: VoiceCommand) {
        let regex = try! NSRegularExpression(pattern: "(?i)\\b\(pattern)\\b")
        let count = replaceAll(regex, kind: .voiceCommand, replacement: { _ in replacement }, rule: command.rawValue)
        counters.commandsApplied += count
    }

    mutating func applySpokenPunctuation() {
        let mappings = [
            ("question\\s+mark", "?"), ("exclamation\\s+(?:mark|point)", "!"),
            ("full\\s+stop", "."), ("period", "."), ("comma", ","),
            ("semicolon", ";"), ("colon", ":")
        ]
        for (pattern, mark) in mappings {
            let regex = try! NSRegularExpression(pattern: "(?i)\\s*\\b\(pattern)\\b")
            counters.punctuationMarksInserted += replaceAll(regex, kind: .spokenPunctuation, replacement: { _ in mark }, rule: pattern)
        }
    }

    mutating func removeFillers(level: CleanupLevel) {
        guard level != .off else { return }
        // Deliberately excludes words such as “like” and “well”: they frequently
        // carry meaning and are unsafe to delete deterministically.
        let regex = try! NSRegularExpression(pattern: "(?i)(?<![\\p{L}\\p{N}])(?:um+|uh+|erm+|ah+)(?![\\p{L}\\p{N}])[, ]*")
        counters.fillersRemoved += replaceAll(regex, kind: .fillerRemoval, replacement: { _ in "" }, rule: "standalone safe filler")
    }

    mutating func removeRepetitions(level: CleanupLevel) {
        guard level != .off else { return }
        // Exact adjacent repetition is safe even for short phrases; no semantic
        // guessing is involved, so conservative mode handles up to three words.
        let maximum = 3
        for length in stride(from: maximum, through: 1, by: -1) {
            let unit = Array(repeating: "([\\p{L}\\p{N}'’-]+)", count: length).joined(separator: "\\s+")
            let references = (1...length).map { "\\s+\\" + String($0) }.joined()
            let regex = try! NSRegularExpression(pattern: "(?i)\\b\(unit)\(references)\\b")
            counters.repetitionsRemoved += replaceAll(regex, kind: .repetitionRemoval, replacement: { match in
                let ns = match as NSString
                return (1...length).map { ns.substring(with: regex.firstMatch(in: match, range: NSRange(location: 0, length: ns.length))!.range(at: $0)) }.joined(separator: " ")
            }, rule: "adjacent \(length)-word repetition")
        }
    }

    mutating func removeFalseStarts(level: CleanupLevel, smart: Bool) {
        guard level == .balanced || level == .aggressive || smart else { return }
        let regex = try! NSRegularExpression(pattern: "(?i)(?:^|(?<=[.!?\\n]))([^.!?\\n]{1,120}?)\\s+(?:actually|no),?\\s+")
        while let match = regex.firstMatch(in: text, range: fullRange), let whole = Range(match.range, in: text) {
            let original = String(text[whole])
            let prefixRange = Range(match.range(at: 1), in: text)!
            let wordCount = text[prefixRange].split(whereSeparator: { $0.isWhitespace }).count
            guard wordCount >= 2 else { break }
            text.replaceSubrange(whole, with: "")
            record(.falseStartRemoval, original, "", "explicit actually/no backtrack")
            counters.falseStartsRemoved += 1
        }
    }

    mutating func formatLists() {
        let markers = ["first", "second", "third", "fourth", "finally"]
        let found = markers.filter { text.range(of: "\\b\($0)\\b", options: [.regularExpression, .caseInsensitive]) != nil }
        guard found.count >= 2 else { return }
        var count = 0
        for marker in markers {
            let regex = try! NSRegularExpression(pattern: "(?i)(?:^|[,;]\\s*)\\b\(marker)\\b[,]?\\s*")
            count += replaceAll(regex, kind: .listFormatting, replacement: { _ in "\n• " }, rule: "spoken ordinal list")
        }
        if count > 0 {
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.hasPrefix("• ") { text = "• " + text }
            counters.listsFormatted += 1
        }
    }

    mutating func applyContextualCleanup() {
        let regex = try! NSRegularExpression(pattern: "\\s+([,.;:!?])")
        _ = replaceAll(regex, kind: .contextualCleanup, replacement: { match in String(match.last!) }, rule: "space before punctuation")
    }

    mutating func normalizeWhitespace() {
        let before = text
        text = text.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: " *\\n *", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        if before != text { record(.normalization, before, text, "whitespace normalization") }
    }

    mutating func finishWhitespace() {
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var fullRange: NSRange { NSRange(text.startIndex..<text.endIndex, in: text) }

    @discardableResult
    mutating func replaceAll(_ regex: NSRegularExpression, kind: RefinementChangeKind, replacement: (String) -> String, rule: String) -> Int {
        var count = 0
        while let match = regex.firstMatch(in: text, range: fullRange), let range = Range(match.range, in: text) {
            let original = String(text[range])
            let output = replacement(original)
            text.replaceSubrange(range, with: output)
            record(kind, original, output, rule)
            count += 1
        }
        return count
    }

    mutating func record(_ kind: RefinementChangeKind, _ original: String, _ replacement: String, _ rule: String) {
        changes.append(RefinementChange(kind: kind, original: original, replacement: replacement, rule: rule))
    }
}
