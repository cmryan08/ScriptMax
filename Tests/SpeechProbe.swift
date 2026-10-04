import Foundation
import AVFoundation
import Speech

@main struct SpeechProbe {
    static func main() async throws {
        print("AVAILABLE: \(SpeechTranscriber.isAvailable)"); fflush(stdout)
        let locales = await SpeechTranscriber.supportedLocales; print("LOCALES: \(locales)"); fflush(stdout)
        let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) ?? Locale(identifier: "en-US")
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
        let status = await AssetInventory.status(forModules: [transcriber])
        print("MODEL: \(status)"); fflush(stdout)
        if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) { try await install.downloadAndInstall() }
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: .init(priority: .userInitiated, modelRetention: .processLifetime))
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: CommandLine.arguments[1]))
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])!
        let converter = AnalyzerInputConverter(analyzerFormat: format)
        try await analyzer.prepareToAnalyze(in: format)
        let stream = AsyncStream<AnalyzerInput>.makeStream()
        let began = Date()
        let reader = Task {
            for try await result in transcriber.results {
                print(String(format: "RESULT +%.2fs audio-end %.2fs: %@", Date().timeIntervalSince(began), CMTimeRangeGetEnd(result.range).seconds, String(result.text.characters)))
            }
        }
        try await analyzer.start(inputSequence: stream.stream)
        while file.framePosition < file.length {
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 512)!
            try file.read(into: buffer)
            for input in try converter.convert(buffer, at: nil) { stream.continuation.yield(input) }
            try await Task.sleep(for: .seconds(Double(buffer.frameLength) / file.processingFormat.sampleRate))
        }
        for input in try converter.flush() { stream.continuation.yield(input) }
        stream.continuation.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        try await reader.value
    }
}
