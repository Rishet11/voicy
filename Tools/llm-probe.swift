import Foundation
import FoundationModels

@main
struct LLMProbe {
    static func main() async {
        guard #available(macOS 26.0, *) else {
            print("availability: macOS 26.0 required")
            return
        }

        print("availability: \(String(describing: SystemLanguageModel.default.availability))")
        let sentence = "I was thinking um that I could probably send the updated message tomorrow morning after I finish the review with everyone"
        for call in 1...3 {
            let start = Date()
            _ = await LLMCleaner().clean(sentence)
            let elapsed = Date().timeIntervalSince(start) * 1000
            print("call \(call): \(String(format: "%.1f", elapsed)) ms")
        }
    }
}
