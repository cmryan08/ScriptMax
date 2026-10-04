import Foundation

struct RecognizedWord: Equatable {
    var text: String
    var confidence: Double? = nil
}

struct ConfidentFollower {
    private(set) var words: [String] = []
    private(set) var position = 0
    private(set) var hasConfidentMatch = false
    private var epochStart = 0
    private var target: [String] = []
    private var ends: [Int] = []
    private struct Token: Equatable { var text: String; var confidence: Double? }
    private struct MatchState {
        var cursor: Int
        var lastSpoken = -1
        var lastTarget = -1
        var strongRun = 0
        var matched = false
    }
    private var occurrences: [String: [Int]] = [:]
    private var previousSpoken: [Token] = []
    private var replayStates: [MatchState] = []
    mutating func load(_ script: String) {
        words = script.split(whereSeparator: \.isWhitespace).map(String.init)
        target = []; ends = []
        for (index, word) in words.enumerated() {
            for token in Self.tokens(word) { target.append(token); ends.append(index + 1) }
        }
        occurrences = [:]
        for index in target.indices { occurrences[target[index], default: []].append(index) }
        position = 0; epochStart = 0; hasConfidentMatch = false
        previousSpoken = []; replayStates = []
    }
    mutating func newUtterance() { epochStart = position; hasConfidentMatch = false; previousSpoken = []; replayStates = [] }
    mutating func move(_ delta: Int) { position = min(words.count, max(0, position + delta)); newUtterance() }
    private static let contractions: [String: [String]] = ["im": ["i", "am"], "ive": ["i", "have"], "ill": ["i", "will"], "dont": ["do", "not"], "doesnt": ["does", "not"], "isnt": ["is", "not"], "cant": ["can", "not"], "its": ["it", "is"], "hes": ["he", "is"], "shes": ["she", "is"], "theyre": ["they", "are"], "youre": ["you", "are"], "thats": ["that", "is"]]
    private static let fillers: Set<String> = ["um", "uh", "erm", "ah", "hmm"]
    private static func tokens(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).flatMap { word -> [String] in
            let normalized = ScriptFollower.normalize(String(word))
            let token = normalized == "okay" ? "ok" : normalized
            guard !token.isEmpty else { return [] }
            if let number = Int(token), number >= 0, number <= 999999 {
                let formatter = NumberFormatter(); formatter.numberStyle = .spellOut; formatter.locale = Locale(identifier: "en_US")
                if let spelled = formatter.string(from: NSNumber(value: number)) {
                    return spelled.replacingOccurrences(of: "-", with: " ").split(whereSeparator: \.isWhitespace).map { ScriptFollower.normalize(String($0)) }
                }
            }
            // Expand contractions only when an apostrophe is present; "ill" is also a real word.
            let apostrophe = word.contains("'") || word.contains("’")
            return apostrophe ? (contractions[token] ?? [token]) : [token]
        }
    }
    private static func similarity(_ a: String, _ b: String) -> Double {
        if a == b { return 1 }
        guard min(a.count, b.count) >= 4, abs(a.count - b.count) <= 2 else { return 0 }
        let x = Array(a), y = Array(b)
        var row = Array(0...y.count)
        for (i, c) in x.enumerated() {
            var next = [i + 1] + Array(repeating: 0, count: y.count)
            for j in y.indices { next[j + 1] = min(next[j] + 1, row[j + 1] + 1, row[j] + (c == y[j] ? 0 : 1)) }
            row = next
        }
        return 1 - Double(row[y.count]) / Double(max(x.count, y.count))
    }
    private func wordPosition(_ cursor: Int) -> Int {
        guard cursor > 0 else { return 0 }
        let wordEnd = ends[cursor - 1]
        // Do not consume a printed contraction/number until all of its spoken tokens match.
        return cursor < ends.count && ends[cursor] == wordEnd ? wordEnd - 1 : wordEnd
    }
    mutating func consume(_ input: [RecognizedWord]) {
        let spoken = input.flatMap { word in Self.tokens(word.text).map { Token(text: $0, confidence: word.confidence) } }
        let initial = MatchState(cursor: ends.firstIndex(where: { $0 > epochStart }) ?? target.count)
        var prefix = 0
        while prefix < min(previousSpoken.count, spoken.count), previousSpoken[prefix] == spoken[prefix] { prefix += 1 }
        // Recheck the short tail because new right-hand context can confirm an earlier
        // misheard word. Stable earlier audio keeps its state rather than being replayed.
        let replayFrom = max(0, prefix - 6)
        var state = replayFrom < replayStates.count ? replayStates[replayFrom] : initial
        var states = replayFrom < replayStates.count ? Array(replayStates.prefix(replayFrom + 1)) : [initial]
        func usable(_ token: Token, minimum: Double = 0.45) -> Bool { token.confidence.map { $0 >= minimum } ?? true }
        for i in replayFrom..<spoken.count {
            let token = spoken[i]
            let cursor = state.cursor
            var accepted: Int?
            var exact = false
            if cursor < target.count, usable(token) {
                let score = Self.similarity(token.text, target[cursor])
                let before = i > 0 && cursor > 0 && spoken[i - 1].text == target[cursor - 1] && usable(spoken[i - 1])
                let after = i + 1 < spoken.count && cursor + 1 < target.count && spoken[i + 1].text == target[cursor + 1] && usable(spoken[i + 1])
                if score == 1 || (score >= 0.8 && (before || after) && usable(token, minimum: 0.6)) {
                    accepted = cursor; exact = score == 1
                }
            }
            // A short substitution/insertion can be bridged by established left
            // context and a distinctive right anchor. No audio word count or timer.
            if accepted == nil, usable(token, minimum: 0.55), state.strongRun >= 2,
               state.lastTarget == cursor - 1, i - state.lastSpoken <= 4, cursor < target.count {
                for skipped in 1...2 where cursor + skipped < target.count {
                    let anchor = cursor + skipped
                    guard target[anchor].count >= 4,
                          Self.similarity(token.text, target[anchor]) >= 0.8 else { continue }
                    let intervening = spoken[(state.lastSpoken + 1)..<i]
                    guard intervening.allSatisfy({ usable($0, minimum: 0.55) }) else { continue }
                    let missing = target[cursor..<anchor]
                    let plausibleSubstitution = missing.contains { expected in
                        expected.count >= 5 && intervening.contains { Self.similarity($0.text, expected) >= 0.55 }
                    }
                    // If the bad word sounds completely different, require two
                    // right-side script words before recovering past it.
                    let nextIsMatched = i + 1 < spoken.count && anchor + 1 < target.count
                        && usable(spoken[i + 1], minimum: 0.55)
                        && Self.similarity(spoken[i + 1].text, target[anchor + 1]) >= 0.8
                    guard plausibleSubstitution || nextIsMatched else { continue }
                    accepted = anchor; exact = token.text == target[anchor]; break
                }
            }
            if accepted == nil, !Self.fillers.contains(token.text), usable(token), i + 1 < spoken.count {
                // Phrase-based relocation handles skipped clauses and deliberate repeats.
                // Indexing occurrences avoids a whole-script scan on every mismatched token.
                var candidates: [(cursor: Int, length: Int)] = []
                for start in occurrences[token.text] ?? [] where start != cursor {
                    let distance = abs(start - cursor)
                    let needed = distance <= 6 ? 2 : 3
                    var length = 0
                    while length < 6, i + length < spoken.count, start + length < target.count,
                          spoken[i + length].text == target[start + length], usable(spoken[i + length], minimum: 0.55) { length += 1 }
                    guard length >= needed else { continue }
                    let phrase = spoken[i..<(i + length)]
                    guard phrase.contains(where: { $0.text.count >= 4 }) || length >= 3 else { continue }
                    candidates.append((start, length))
                }
                candidates.sort {
                    if $0.length != $1.length { return $0.length > $1.length }
                    return abs($0.cursor - cursor) < abs($1.cursor - cursor)
                }
                if let best = candidates.first {
                    let ambiguous = candidates.count > 1 && candidates[1].length == best.length
                        && abs(abs(candidates[1].cursor - cursor) - abs(best.cursor - cursor)) <= 2
                    if !ambiguous { accepted = best.cursor; exact = true }
                }
            }
            if let accepted {
                state.strongRun = exact ? (state.lastTarget == accepted - 1 && state.lastSpoken == i - 1 ? state.strongRun + 1 : 1) : 0
                state.lastTarget = accepted; state.lastSpoken = i; state.cursor = accepted + 1; state.matched = true
            } else if !Self.fillers.contains(token.text) { state.matched = false }
            states.append(state)
        }
        previousSpoken = spoken; replayStates = states
        position = wordPosition(state.cursor)
        hasConfidentMatch = state.matched
    }
    func phrase(_ count: Int) -> String { words.dropFirst(position).prefix(count).joined(separator: " ") }
    func upcoming(_ count: Int) -> String { words.dropFirst(position + count).prefix(12).joined(separator: " ") }
    func twoLines(_ count: Int) -> [String] {
        let remaining = Array(words.dropFirst(position).prefix(count))
        guard !remaining.isEmpty else { return ["All done.", ""] }
        let split = (remaining.count + 1) / 2
        return [remaining.prefix(split).joined(separator: " "), remaining.dropFirst(split).joined(separator: " ")]
    }
}
