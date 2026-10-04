import Foundation

struct ScriptFollower {
    private(set) var words: [String] = []
    private(set) var position = 0
    private var anchor = 0
    private var spokenWordCount = 0
    private var normalizedWords: [String] = []
    private var smartWords: [String] = []
    private var smartEnds: [Int] = []
    private var previousSpoken: [String] = []
    private var checkpoints: [Int] = []
    private(set) var confirmedPosition = 0
    private(set) var smartLocked = false
    mutating func load(_ script: String) {
        words = script.split(whereSeparator: \.isWhitespace).map(String.init)
        position = 0; anchor = 0; spokenWordCount = 0
        normalizedWords = words.map(Self.normalize)
        smartWords = []; smartEnds = []
        for (i, word) in words.enumerated() {
            for token in Self.tokens(word) { smartWords.append(token); smartEnds.append(i + 1) }
        }
        confirmedPosition = 0; previousSpoken = []; checkpoints = []; smartLocked = false
    }
    mutating func newUtterance() {
        // Never treat a speculative display advance as confirmed speech after pause.
        position = min(position, confirmedPosition > 0 ? confirmedPosition : position)
        anchor = position; confirmedPosition = position; spokenWordCount = 0
        previousSpoken = []; checkpoints = []; smartLocked = false
    }
    mutating func move(_ delta: Int) { position = min(words.count, max(0, position + delta)); anchor = position; confirmedPosition = position; spokenWordCount = 0; previousSpoken = []; checkpoints = []; smartLocked = false }
    static func normalize(_ word: String) -> String {
        word.lowercased().folding(options: [.diacriticInsensitive], locale: .current)
            .filter { $0.isLetter || $0.isNumber }
    }
    mutating func consumeEveryWord(_ transcript: String) {
        let count = transcript.split(whereSeparator: \.isWhitespace).filter { !Self.normalize(String($0)).isEmpty }.count
        let added = max(0, count - spokenWordCount)
        position = min(words.count, position + added)
        // A partial result can shrink or change spelling. Only genuinely new word slots advance.
        spokenWordCount = max(spokenWordCount, count)
        confirmedPosition = position
    }
    mutating func consume(_ transcript: String) {
        let spoken = transcript.split(whereSeparator: \.isWhitespace).map { Self.normalize(String($0)) }.filter { !$0.isEmpty }
        let target = normalizedWords
        var cursor = anchor
        for (i, token) in spoken.enumerated() {
            guard cursor < target.count else { break }
            if target[cursor] == token { cursor += 1; continue }
            // A pair of consecutive words permits a small omission, but a stray word cannot jump ahead.
            if i + 1 < spoken.count {
                let end = min(target.count - 1, cursor + 5)
                if cursor + 1 < end, let hit = ((cursor + 1)..<end).first(where: {
                    target[$0] == token && target[$0 + 1] == spoken[i + 1]
                }) { cursor = hit + 1 }
            }
        }
        position = max(position, cursor)
        confirmedPosition = position
    }
    private static let fillers: Set<String> = ["um", "uh", "erm", "ah", "hmm", "like", "well"]
    private static func tokens(_ text: String) -> [String] {
        let contractions: [String: [String]] = ["im": ["i", "am"], "ive": ["i", "have"], "ill": ["i", "will"], "dont": ["do", "not"], "doesnt": ["does", "not"], "isnt": ["is", "not"], "cant": ["can", "not"], "its": ["it", "is"], "hes": ["he", "is"], "shes": ["she", "is"], "theyre": ["they", "are"], "youre": ["you", "are"], "thats": ["that", "is"]]
        let homophones: [String: String] = ["two": "to", "too": "to", "their": "there", "theyre": "there", "four": "for", "bread": "brad"]
        return text.split(whereSeparator: \.isWhitespace).flatMap { word -> [String] in
            let normalized = normalize(String(word))
            guard !normalized.isEmpty else { return [] }
            if let number = Int(normalized), number >= 0, number <= 999999 {
                let formatter = NumberFormatter(); formatter.numberStyle = .spellOut; formatter.locale = Locale(identifier: "en_US")
                if let spelled = formatter.string(from: NSNumber(value: number)) {
                    return spelled.replacingOccurrences(of: "-", with: " ").split(whereSeparator: \.isWhitespace).map { normalize(String($0)) }
                }
            }
            return contractions[normalized] ?? [homophones[normalized] ?? normalized]
        }
    }
    private static func similar(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        guard min(a.count, b.count) >= 4, abs(a.count - b.count) <= 2 else { return false }
        let x = Array(a), y = Array(b)
        var row = Array(0...y.count)
        for (i, c) in x.enumerated() {
            var next = [i + 1] + Array(repeating: 0, count: y.count)
            for j in y.indices { next[j + 1] = min(next[j] + 1, row[j + 1] + 1, row[j] + (c == y[j] ? 0 : 1)) }
            row = next
        }
        return row[y.count] <= max(1, min(a.count, b.count) / 4)
    }
    mutating func consumeSmart(_ transcript: String) {
        let spoken = Self.tokens(transcript)
        var common = 0
        while common < min(spoken.count, previousSpoken.count), spoken[common] == previousSpoken[common] { common += 1 }
        let replay = max(0, common - 4)
        let start = smartEnds.firstIndex(where: { $0 > anchor }) ?? smartWords.count
        var cursor = replay > 0 && replay <= checkpoints.count ? checkpoints[replay - 1] : start
        checkpoints = Array(checkpoints.prefix(replay))
        var matches = 0, misses = 0
        for i in replay..<spoken.count {
            let token = spoken[i]
            if cursor < smartWords.count {
                if Self.similar(token, smartWords[cursor]) {
                    cursor += 1; matches += 1; misses = 0
                } else if Self.fillers.contains(token) {
                    // Filler speech holds the script in place.
                } else {
                    let stop = min(smartWords.count, cursor + 24)
                    var hit: Int?
                    if cursor + 1 < stop {
                        hit = ((cursor + 1)..<stop).first { k in
                            guard Self.similar(token, smartWords[k]) else { return false }
                            let nextMatches = i + 1 < spoken.count && k + 1 < smartWords.count && Self.similar(spoken[i + 1], smartWords[k + 1])
                            return (nextMatches && (token.count >= 4 || spoken[i + 1].count >= 4 || k - cursor <= 2)) || (k == cursor + 1 && token.count >= 4 && (matches > 0 || confirmedPosition > anchor))
                        }
                    }
                    if let hit { cursor = hit + 1; matches += 1; misses = 0 }
                    else if i + 1 < spoken.count, cursor + 1 < smartWords.count,
                            Self.similar(spoken[i + 1], smartWords[cursor + 1]), (matches > 0 || confirmedPosition > anchor) {
                        // A rough substitution between recognizable words can be consumed immediately.
                        cursor += 1; misses += 1
                    } else { misses += 1 }
                }
            }
            checkpoints.append(cursor)
        }
        previousSpoken = spoken
        let endpoint = cursor > start ? smartEnds[cursor - 1] : anchor
        confirmedPosition = max(confirmedPosition, endpoint)
        position = max(position, confirmedPosition)
        smartLocked = confirmedPosition >= anchor + 2 && misses < 3
    }
    mutating func anticipateWord() {
        guard smartLocked else { return }
        position = min(words.count, min(confirmedPosition + 2, position + 1))
    }
    func phrase(_ count: Int) -> String { words.dropFirst(position).prefix(count).joined(separator: " ") }
    func upcoming(_ count: Int) -> String { words.dropFirst(position + count).prefix(12).joined(separator: " ") }
}
