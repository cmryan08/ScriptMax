import Foundation

@main struct FollowingProbe {
    static func main() throws {
        let script = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
        let log = try String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8)
        var follower = ConfidentFollower()
        follower.load(script)
        var updates = 0
        for line in log.split(separator: "\n") where line.hasPrefix("PARTIAL ") {
            guard let separator = line.range(of: ": ") else { continue }
            let text = line[separator.upperBound...]
            follower.consume(text.split(whereSeparator: \.isWhitespace).map { RecognizedWord(text: String($0)) })
            updates += 1
        }
        print("Streaming partial updates: \(updates); script progress: \(follower.position)/\(follower.words.count)")
        guard follower.position == follower.words.count else { throw NSError(domain: "Following did not reach the script end", code: 1) }
    }
}
