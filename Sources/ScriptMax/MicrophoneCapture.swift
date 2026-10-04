import AVFoundation

// Capture sample buffers directly rather than waiting for AVAudioEngine's 100–400 ms tap batching.
final class MicrophoneCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "ScriptMax.microphone", qos: .userInteractive)
    private var generation = 0
    private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var onActivity: ((Bool) -> Void)?
    private var readyCallback: ((String?) -> Void)?
    private var noiseFloor = 0.001
    private var lastVoiceTime = 0.0
    private var lastPublish = 0.0
    func start(continuation: AsyncStream<AVAudioPCMBuffer>.Continuation, onActivity: @escaping (Bool) -> Void, completion: @escaping (String?) -> Void) {
        queue.async {
            self.generation += 1
            self.session.beginConfiguration()
            self.session.inputs.forEach { self.session.removeInput($0) }
            self.session.outputs.forEach { self.session.removeOutput($0) }
            do {
                guard let device = AVCaptureDevice.default(for: .audio) else { throw NSError(domain: "No microphone available", code: 1) }
                let input = try AVCaptureDeviceInput(device: device)
                guard self.session.canAddInput(input) else { throw NSError(domain: "Microphone unavailable", code: 2) }
                self.session.addInput(input)
                let output = AVCaptureAudioDataOutput()
                output.audioSettings = [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVNumberOfChannelsKey: 1]
                output.setSampleBufferDelegate(self, queue: self.queue)
                guard self.session.canAddOutput(output) else { throw NSError(domain: "Audio capture unavailable", code: 3) }
                self.session.addOutput(output); self.session.commitConfiguration()
                self.continuation = continuation; self.onActivity = onActivity
                self.noiseFloor = 0.001; self.lastVoiceTime = 0; self.lastPublish = 0
                self.readyCallback = completion
                self.session.startRunning()
                if !self.session.isRunning {
                    self.readyCallback = nil
                    DispatchQueue.main.async { completion("Microphone capture did not start.") }
                } else {
                    let epoch = self.generation
                    self.queue.asyncAfter(deadline: .now() + 4) {
                        guard self.generation == epoch, let callback = self.readyCallback else { return }
                        self.readyCallback = nil
                        DispatchQueue.main.async { callback("The microphone opened but is not delivering audio. Check your input device in System Settings → Sound.") }
                    }
                }
            } catch {
                self.session.commitConfiguration()
                DispatchQueue.main.async { completion(error.localizedDescription) }
            }
        }
    }
    func stop() {
        queue.async {
            self.generation += 1; self.session.stopRunning()
            self.continuation = nil; self.onActivity = nil; self.readyCallback = nil
        }
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let continuation,
              let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let format = AVAudioFormat(streamDescription: asbd) else { return }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList) == noErr else { return }
        if let data = buffer.floatChannelData?[0] {
            var sum = 0.0
            for i in 0..<Int(frames) { let sample = Double(data[i]); sum += sample * sample }
            let rms = sqrt(sum / Double(frames))
            // Adapt only downward/quietly; normal speech must not raise the noise gate indefinitely.
            if rms < noiseFloor * 2 { noiseFloor = max(0.0003, noiseFloor * 0.97 + rms * 0.03) }
            let now = Date.timeIntervalSinceReferenceDate
            if rms > max(0.004, noiseFloor * 3.5) { lastVoiceTime = now }
            if now - lastPublish >= 0.035 {
                lastPublish = now
                let voiced = now - lastVoiceTime < 0.09
                let callback = onActivity
                DispatchQueue.main.async { callback?(voiced) }
            }
        }
        continuation.yield(buffer)
        if let callback = readyCallback {
            readyCallback = nil
            DispatchQueue.main.async { callback(nil) }
        }
    }
}
