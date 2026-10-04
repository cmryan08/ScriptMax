import Foundation

struct ReadingPacer {
    private var lastConfirmedAt: Double?
    private var lastConfirmed = 0
    private var lastVoiceAt = -Double.infinity
    private var lastAdvanceAt = -Double.infinity
    private var lastResultAt = -Double.infinity
    private var wordsPerSecond = 3.5
    mutating func reset(position: Int = 0) { self = ReadingPacer(); lastConfirmed = position }
    mutating func activity(_ voiced: Bool, now: Double) { if voiced { lastVoiceAt = now } }
    mutating func confirmed(_ position: Int, now: Double) {
        lastResultAt = now
        let delta = position - lastConfirmed
        guard delta > 0 else { return }
        if let previous = lastConfirmedAt, now - previous > 0.06, now - previous < 2 {
            let measured = min(6, max(1.3, Double(delta) / (now - previous)))
            wordsPerSecond = wordsPerSecond * 0.55 + measured * 0.45
        }
        lastConfirmed = position; lastConfirmedAt = now; lastAdvanceAt = now
    }
    mutating func shouldAdvance(now: Double, aligned: Bool) -> Bool {
        guard aligned, now - lastVoiceAt < 0.13, now - lastResultAt < 0.8,
              now - lastAdvanceAt >= max(0.06, 0.4 / wordsPerSecond) else { return false }
        lastAdvanceAt = now
        return true
    }
}
