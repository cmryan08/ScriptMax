import Foundation

struct TranscriptAccumulator {
    private var segments: [(start: Double, end: Double, text: String, words: [RecognizedWord])] = []
    mutating func update(start: Double, end: Double, text: String) -> String {
        segments.removeAll {
            abs($0.start - start) < 0.001 || ($0.start < end - 0.001 && $0.end > start + 0.001)
        }
        segments.append((start, end, text, text.split(whereSeparator: \.isWhitespace).map { RecognizedWord(text: String($0)) }))
        segments.sort { $0.start < $1.start }
        return segments.map(\.text).joined(separator: " ")
    }
    mutating func update(start: Double, end: Double, words: [RecognizedWord]) -> [RecognizedWord] {
        segments.removeAll { abs($0.start - start) < 0.001 || ($0.start < end - 0.001 && $0.end > start + 0.001) }
        segments.append((start, end, words.map(\.text).joined(separator: " "), words))
        segments.sort { $0.start < $1.start }
        return segments.flatMap(\.words)
    }

}
