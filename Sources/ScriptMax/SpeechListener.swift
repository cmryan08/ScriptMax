import Foundation
import AVFoundation
import CoreML
import FluidAudio

// Cached CoreML models; audio is processed sequentially to avoid overlapping decoder state.
final class SpeechListener {
    private let microphone = MicrophoneCapture()
    private var engine: StreamingNemotronAsrManager?
    private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var startupTask: Task<Void, Never>?
    private var resultTask: Task<Void, Never>?
    private var drainingTask: Task<Void, Never>?
    private var generation = 0
    var onActivity: ((Bool) -> Void)?
    var onActive: ((Bool) -> Void)?
    var onWords: (([RecognizedWord]) -> Void)?
    var onEpoch: (() -> Void)?
    var onStatus: ((String) -> Void)?
    var context = ""

    func start() {
        stop()
        let epoch = generation
        let previous = drainingTask
        onStatus?("Preparing Nemotron streaming recognition…")
        startupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let permission = AVCaptureDevice.authorizationStatus(for: .audio)
            let granted = permission == .authorized ? true : await AVCaptureDevice.requestAccess(for: .audio)
            guard epoch == self.generation, !Task.isCancelled else { return }
            guard granted else { self.fail("Enable Microphone access for ScriptMax in System Settings → Privacy & Security."); return }
            do {
                await previous?.value
                guard epoch == self.generation, !Task.isCancelled else { return }
                let engine: StreamingNemotronAsrManager
                if let cached = self.engine { engine = cached }
                else {
                    self.onStatus?("Loading Nemotron 600M • first use downloads the local model…")
                    let configuration = MLModelConfiguration()
                    configuration.computeUnits = .cpuAndNeuralEngine
                    engine = StreamingNemotronAsrManager(configuration: configuration, requestedChunkSize: .ms560)
                    // Keep downloaded models inside this app's own directory.
                    let directory = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("SpeechModels", isDirectory: true)
                    try await engine.loadModels(to: directory, progressHandler: { [weak self] progress in
                        Task { @MainActor in
                            guard let self, epoch == self.generation else { return }
                            switch progress.phase {
                            case .listing: self.onStatus?("Checking Nemotron model files…")
                            case .downloading: self.onStatus?("Downloading Nemotron model • \(Int(progress.fractionCompleted * 100))%")
                            case .compiling: self.onStatus?("Optimizing Nemotron for this Mac…")
                            }
                        }
                    })
                    guard epoch == self.generation, !Task.isCancelled else { return }
                    self.onStatus?("Warming up Nemotron for live reading…")
                    let warmFormat = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
                    let silence = AVAudioPCMBuffer(pcmFormat: warmFormat, frameCapacity: 8960)!
                    silence.frameLength = 8960
                    memset(silence.floatChannelData![0], 0, Int(silence.frameLength) * MemoryLayout<Float>.size)
                    _ = try await engine.process(audioBuffer: silence)
                    guard epoch == self.generation, !Task.isCancelled else { return }
                    self.engine = engine
                }
                await engine.reset()
                guard epoch == self.generation, !Task.isCancelled else { return }
                await engine.setPartialCallback { [weak self] text in
                    Task { @MainActor in
                        guard let self, epoch == self.generation else { return }
                        // This engine has no calibrated word confidence API. Script/context checks
                        // remain the gate; don't invent confidence values from token likelihoods.
                        self.onWords?(text.split(whereSeparator: \.isWhitespace).map { RecognizedWord(text: String($0)) })
                    }
                }
                self.onEpoch?()
                // Unbounded preserves every sample; this engine must stay faster than real time.
                let stream = AsyncStream<AVAudioPCMBuffer>.makeStream()
                self.continuation = stream.continuation
                self.resultTask = Task { [weak self] in
                    do {
                        for await buffer in stream.stream {
                            guard let self, epoch == self.generation, !Task.isCancelled else { return }
                            _ = try await engine.process(audioBuffer: buffer)
                        }
                    } catch {
                        await MainActor.run { if let self, epoch == self.generation { self.fail("Nemotron stopped: \(error.localizedDescription)") } }
                    }
                }
                self.microphone.start(continuation: stream.continuation, onActivity: { [weak self] voiced in
                    guard let self, epoch == self.generation else { return }; self.onActivity?(voiced)
                }, completion: { [weak self] error in
                    guard let self, epoch == self.generation else { return }
                    if let error { self.fail(error) }
                    else { self.onActive?(true); self.onStatus?("Listening • Nemotron 600M • 560 ms streaming") }
                })
            } catch { if epoch == self.generation { self.fail("Nemotron could not start: \(error.localizedDescription)") } }
        }
    }
    private func fail(_ message: String) { stop(); onStatus?(message) }
    func stop() {
        generation += 1
        let startup = startupTask, processing = resultTask, prior = drainingTask
        startup?.cancel(); startupTask = nil
        microphone.stop(); onActivity?(false)
        continuation?.finish(); continuation = nil; processing?.cancel(); resultTask = nil
        drainingTask = Task { await prior?.value; await startup?.value; await processing?.value }
        onActive?(false)
    }
}
