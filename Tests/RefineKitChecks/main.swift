import Foundation
import RefineKit

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

@main
enum RefineKitChecks {
    static func main() {
        let refiner = LocalTranscriptRefiner()

        let clean = refiner.refineSynchronously("Um, I I need this comma uh today question mark")
        require(clean.refinedText == "I need this, today?", "safe fillers, repetition, or punctuation failed: \(clean.refinedText)")
        require(clean.counters.fillersRemoved == 2, "filler counter")
        require(clean.counters.repetitionsRemoved == 1, "repetition counter")
        require(clean.counters.punctuationMarksInserted == 2, "punctuation counter")

        let phrases = refiner.refineSynchronously("we need to we need to ship")
        require(phrases.refinedText == "we need to ship", "short phrase repetition")

        let commands = refiner.refineSynchronously("alpha new line beta new paragraph bullet point gamma")
        require(commands.refinedText == "alpha\nbeta\n\n• gamma", "voice command formatting: \(commands.refinedText.debugDescription)")
        require(commands.detectedCommands == [.newLine, .newParagraph, .bulletPoint], "command reporting")

        let scratch = refiner.refineSynchronously("Send this to Sam scratch that Send this to Alex")
        require(scratch.refinedText == "Send this to Alex", "scratch that semantics: \(scratch.refinedText)")

        let literal = refiner.refineSynchronously("The word literal um and say literal comma")
        require(literal.refinedText == "The word um and say comma", "literal protection: \(literal.refinedText)")

        let meaningful = refiner.refineSynchronously("Well I like this")
        require(meaningful.refinedText == "Well I like this", "meaningful words were removed")

        let balanced = refiner.refineSynchronously("send this to Sam actually send this to Alex", configuration: .init(cleanupLevel: .balanced))
        require(balanced.refinedText == "send this to Alex", "false-start cleanup: \(balanced.refinedText)")

        let conservative = refiner.refineSynchronously("send this to Sam actually send this to Alex")
        require(conservative.refinedText.contains("actually"), "conservative cleanup was too destructive")

        let fast = refiner.refineSynchronously("um  hello comma", mode: .fast)
        require(fast.refinedText == "um hello comma", "fast mode did more than normalization")

        let off = refiner.refineSynchronously("um um hello comma", configuration: .disabled)
        require(off.refinedText == "um um hello comma", "off mode transformed content")

        let list = refiner.refineSynchronously("first milk, second bread, finally coffee")
        require(list.refinedText == "• milk\n• bread\n• coffee", "list formatting: \(list.refinedText.debugDescription)")

        let encoded = try! JSONEncoder().encode(clean)
        let decoded = try! JSONDecoder().decode(RefinementResult.self, from: encoded)
        require(decoded == clean, "Codable round trip")
        require(clean.changes.contains { $0.kind == .fillerRemoval }, "typed change reporting")

        print("ALL REFINEKIT CHECKS PASSED")
    }
}
