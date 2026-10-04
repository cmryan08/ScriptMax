import Foundation
import AVFoundation
import CoreML
import FluidAudio

@main struct Probe {
    static func main() async throws {
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine
        let engine: any StreamingAsrManager
        let models = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/SpeechModels")
        if CommandLine.arguments.contains("--nemotron") {
            let candidate = StreamingNemotronAsrManager(configuration: config, requestedChunkSize: .ms560)
            try await candidate.loadModels(to: models)
            engine = candidate
        } else {
            let candidate = StreamingEouAsrManager(configuration: config, chunkSize: .ms160)
            try await candidate.loadModels(to: models)
            engine = candidate
        }
        let source = try AVAudioFile(forReading: URL(fileURLWithPath: CommandLine.arguments[1]))
        let clock = ContinuousClock()
        let start = clock.now
        await engine.setPartialTranscriptCallback { text in
            print("PARTIAL \(start.duration(to: clock.now)): \(text)")
        }
        let frames = AVAudioFrameCount(source.processingFormat.sampleRate * 0.02)
        var audioSeconds = 0.0
        var inferenceSeconds = 0.0
        while source.framePosition < source.length {
            let buffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: frames)!
            try source.read(into: buffer)
            audioSeconds += Double(buffer.frameLength) / source.processingFormat.sampleRate
            let before = clock.now
            try await engine.appendAudio(buffer)
            try await engine.processBufferedAudio()
            let duration = before.duration(to: clock.now).components
            inferenceSeconds += Double(duration.seconds) + Double(duration.attoseconds) / 1e18
            if CommandLine.arguments.contains("--realtime") {
                try await clock.sleep(until: start.advanced(by: .seconds(audioSeconds)))
            }
        }
        let final = try await engine.finish()
        print("FINAL: \(final)")
        print("Audio: \(audioSeconds)s; inference: \(inferenceSeconds)s")
        guard !final.isEmpty else { throw NSError(domain: "Empty transcript", code: 1) }
    }
}
