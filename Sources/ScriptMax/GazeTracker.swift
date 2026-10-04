import AppKit
import AVFoundation
import Vision

final class GazeTracker: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "ScriptMax.camera")
    private var configured = false
    private var frame = 0
    var onFeature: ((CGPoint?) -> Void)?
    var onStatus: ((String) -> Void)?
    func start() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self else { return }
            guard granted else { DispatchQueue.main.async { self.onStatus?("Camera permission is required for gaze tracking.") }; return }
            self.queue.async {
                do {
                    if !self.configured {
                        guard let camera = AVCaptureDevice.default(for: .video) else { throw NSError(domain: "Camera unavailable", code: 1) }
                        let input = try AVCaptureDeviceInput(device: camera)
                        self.session.beginConfiguration(); self.session.sessionPreset = .hd1280x720
                        guard self.session.canAddInput(input) else { self.session.commitConfiguration(); throw NSError(domain: "Camera busy", code: 2) }
                        self.session.addInput(input)
                        let output = AVCaptureVideoDataOutput(); output.alwaysDiscardsLateVideoFrames = true
                        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                        output.setSampleBufferDelegate(self, queue: self.queue)
                        guard self.session.canAddOutput(output) else { self.session.commitConfiguration(); throw NSError(domain: "Camera output unavailable", code: 3) }
                        self.session.addOutput(output); self.session.commitConfiguration(); self.configured = true
                    }
                    self.session.startRunning()
                    DispatchQueue.main.async { self.onStatus?("Camera active • calibrate before following gaze") }
                } catch { DispatchQueue.main.async { self.onStatus?(error.localizedDescription) } }
            }
        }
    }
    func stop() { queue.async { self.session.stopRunning() }; onFeature?(nil) }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        frame += 1; guard frame % 2 == 0, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let request = VNDetectFaceLandmarksRequest()
        try? VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up).perform([request])
        var feature: CGPoint?
        if let face = request.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width }), let marks = face.landmarks {
            func relative(_ pupil: VNFaceLandmarkRegion2D?, _ eye: VNFaceLandmarkRegion2D?) -> CGPoint? {
                guard let eye, eye.pointCount > 3 else { return nil }
                let points = eye.normalizedPoints.map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) }
                let xs = points.map(\.x), ys = points.map(\.y)
                let left = xs.min()!, bottom = ys.min()!, width = xs.max()! - left, height = ys.max()! - bottom
                guard width > 0.01, height / width > 0.15 else { return nil }
                // Vision finds eye outlines; use actual dark iris pixels inside each outline for gaze.
                let box = face.boundingBox
                let pixelWidth = CVPixelBufferGetWidth(buffer), pixelHeight = CVPixelBufferGetHeight(buffer)
                let polygon = points.map { CGPoint(x: (box.minX + $0.x * box.width) * CGFloat(pixelWidth), y: (1 - box.minY - $0.y * box.height) * CGFloat(pixelHeight)) }
                guard let center = Self.darkIris(buffer, polygon: polygon) else { return nil }
                let localX = (center.x / CGFloat(pixelWidth) - box.minX) / box.width
                let localY = (1 - center.y / CGFloat(pixelHeight) - box.minY) / box.height
                return CGPoint(x: (localX - left) / width, y: (localY - bottom) / height)
            }
            if let l = relative(marks.leftPupil, marks.leftEye), let r = relative(marks.rightPupil, marks.rightEye) {
                feature = CGPoint(x: (l.x + r.x) / 2, y: (l.y + r.y) / 2)
            }
        }
        let value = feature
        DispatchQueue.main.async { self.onFeature?(value) }
    }
    private static func darkIris(_ buffer: CVPixelBuffer, polygon: [CGPoint]) -> CGPoint? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let minX = polygon.map(\.x).min()!, maxX = polygon.map(\.x).max()!
        let minY = polygon.map(\.y).min()!, maxY = polygon.map(\.y).max()!
        guard maxX - minX >= 12, maxY - minY >= 4 else { return nil }
        var pixels: [(Double, Double, Double)] = []
        let lowY = max(0, Int(minY + (maxY - minY) * 0.22))
        let highY = min(CVPixelBufferGetHeight(buffer) - 1, Int(maxY - (maxY - minY) * 0.15))
        guard highY > lowY else { return nil }
        for y in lowY...highY {
            var crossings: [Double] = []
            for i in polygon.indices {
                let a = polygon[i], b = polygon[(i + 1) % polygon.count]
                if (a.y > CGFloat(y)) != (b.y > CGFloat(y)) {
                    crossings.append(Double(a.x + (CGFloat(y) - a.y) * (b.x - a.x) / (b.y - a.y)))
                }
            }
            guard let l = crossings.min(), let r = crossings.max() else { continue }
            let lo = max(0, Int(max(l + 1, minX + (maxX - minX) * 0.1)))
            let hi = min(CVPixelBufferGetWidth(buffer) - 1, Int(min(r - 1, maxX - (maxX - minX) * 0.1)))
            guard hi >= lo else { continue }
            for x in lo...hi {
                let offset = y * stride + x * 4
                let brightness = 0.114 * Double(bytes[offset]) + 0.587 * Double(bytes[offset + 1]) + 0.299 * Double(bytes[offset + 2])
                pixels.append((Double(x), Double(y), brightness))
            }
        }
        guard pixels.count > 30 else { return nil }
        let sorted = pixels.map { $0.2 }.sorted()
        let dark = sorted[sorted.count / 10], light = sorted[sorted.count * 8 / 10]
        guard light - dark > 12 else { return nil }
        let threshold = dark + (light - dark) * 0.45
        var sum = 0.0, x = 0.0, y = 0.0
        for p in pixels where p.2 < threshold {
            let weight = threshold - p.2
            sum += weight; x += p.0 * weight; y += p.1 * weight
        }
        guard sum > 0 else { return nil }
        return CGPoint(x: x / sum, y: y / sum)
    }

}

struct GazeCalibration {
    var samples: [(CGPoint, CGPoint)] = []
    private(set) var xCoefficients: [Double] = []
    private(set) var yCoefficients: [Double] = []
    var ready: Bool { xCoefficients.count == 3 }
    mutating func fit() -> Bool {
        guard samples.count >= 5 else { return false }
        func solve(_ axis: (CGPoint) -> CGFloat) -> [Double]? {
            var matrix = Array(repeating: Array(repeating: 0.0, count: 4), count: 3)
            for (feature, target) in samples {
                let row = [1.0, Double(feature.x), Double(feature.y)]
                for i in 0..<3 { for j in 0..<3 { matrix[i][j] += row[i] * row[j] }; matrix[i][3] += row[i] * Double(axis(target)) }
            }
            for i in 0..<3 {
                let pivot = (i..<3).max(by: { abs(matrix[$0][i]) < abs(matrix[$1][i]) })!
                matrix.swapAt(i, pivot)
                guard abs(matrix[i][i]) > 0.000001 else { return nil }
                let scale = matrix[i][i]; for j in i..<4 { matrix[i][j] /= scale }
                for k in 0..<3 where k != i { let factor = matrix[k][i]; for j in i..<4 { matrix[k][j] -= factor * matrix[i][j] } }
            }
            return matrix.map { $0[3] }
        }
        guard let x = solve({ $0.x }), let y = solve({ $0.y }) else { return false }
        xCoefficients = x; yCoefficients = y; return true
    }
    func map(_ feature: CGPoint) -> CGPoint? {
        guard ready else { return nil }
        let row = [1.0, Double(feature.x), Double(feature.y)]
        return CGPoint(x: zip(row, xCoefficients).reduce(0) { $0 + $1.0 * $1.1 }, y: zip(row, yCoefficients).reduce(0) { $0 + $1.0 * $1.1 })
    }
}
