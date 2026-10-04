import SwiftUI
import AppKit

@main
struct ScriptMaxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        WindowGroup("ScriptMax") { EditorView(model: delegate.model).frame(minWidth: 680, minHeight: 620) }
        .windowStyle(.hiddenTitleBar)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = PrompterModel()
    func applicationDidFinishLaunching(_ notification: Notification) { NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true) }
    func applicationWillTerminate(_ notification: Notification) { model.stop(); model.gaze.stop() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
final class PrompterModel: ObservableObject {
    @Published var script: String = UserDefaults.standard.string(forKey: "script") ?? "Hi, my name is Chris, and the weather’s great today. This is my script. I can keep talking while the words advance as I speak."
    @Published var chunk = UserDefaults.standard.object(forKey: "maximumPreviewWords") as? Int ?? 10 {
        didSet { UserDefaults.standard.set(chunk, forKey: "maximumPreviewWords") }
    }
    @Published var boxScale = UserDefaults.standard.object(forKey: "previewBoxScale") as? Double ?? 1.0 {
        didSet { UserDefaults.standard.set(boxScale, forKey: "previewBoxScale") }
    }
    @Published var fontSize = 12.0
    @Published var compactOverlay = true
    @Published var minimumFontScale = 0.85
    @Published var sevenBoxes = true
    @Published var visibleBoxCount = 0
    @Published var hoveredBoxes: Set<Int> = []
    @Published var follower = ConfidentFollower()
    @Published var running = false
    @Published var status = "Paste your script, then start reading."
    @Published var cameraStatus = "Camera off"
    @Published var gazeEnabled = false
    @Published var calibrated = false
    @Published var transcript = ""
    @Published var eyesVisible = false
    @Published var calibrationIndex = 0
    @Published var calibrationMessage = "Look at the dot. Each point takes about 1.4 seconds."
    let speech = SpeechListener()
    let gaze = GazeTracker()
    private var overlays: [NSPanel] = []
    private var overlay: NSPanel? { overlays.first }
    private var calibrationPanel: NSPanel?
    private var calibrationTimer: Timer?
    private var calibration = GazeCalibration()
    private var features: [CGPoint] = []
    private var stepStart = Date()
    private var smoothed: CGPoint?
    private var lastMovement = Date.distantPast
    private var selectedScreen: NSScreen { NSScreen.main ?? NSScreen.screens[0] }
    private var trackingScreen: NSScreen?
    let targets = [CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.18, y: 0.2), CGPoint(x: 0.82, y: 0.2), CGPoint(x: 0.82, y: 0.8), CGPoint(x: 0.18, y: 0.8), CGPoint(x: 0.5, y: 0.5)]
    init() {
        follower.load(script)
        speech.onActive = { [weak self] in self?.running = $0 }
        speech.onWords = { [weak self] words in
            guard let self else { return }
            self.transcript = words.map(\.text).joined(separator: " ")
            self.follower.consume(words)
            self.resizeOverlay()
            if self.follower.position == self.follower.words.count { self.status = "Script complete" }
        }
        speech.onEpoch = { [weak self] in self?.follower.newUtterance() }
        speech.onStatus = { [weak self] in self?.status = $0 }
        gaze.onStatus = { [weak self] in self?.cameraStatus = $0 }
        gaze.onFeature = { [weak self] in self?.receive($0) }
    }
    func scriptEdited() {
        if running { stop() }
        follower.load(script); transcript = ""
        speech.context = script
        UserDefaults.standard.set(script, forKey: "script")
    }
    func start() {
        UserDefaults.standard.set(script, forKey: "script")
        speech.stop(); follower.load(script); transcript = ""
        guard !follower.words.isEmpty else { status = "Paste a script first."; return }
        running = true; showOverlay(); speech.context = script; speech.start()
    }
    func pause() {
        if running { running = false; speech.stop(); status = "Paused" }
        else { running = true; speech.start() }
    }
    func stop() { running = false; speech.stop(); overlays.forEach { $0.orderOut(nil) }; visibleBoxCount = 0; status = "Stopped" }
    func move(_ delta: Int) {
        follower.move(delta)
        // Start a fresh recognition transcript so earlier spoken words cannot undo a manual correction.
        if running { speech.stop(); running = true; speech.start() }
    }
    var readingWidth: CGFloat {
        if compactOverlay {
            // A larger word limit provides a larger reading area, while keeping
            // the same font range and two-line layout.
            return max(74, fontSize * 7 * max(1, Double(chunk) / 6) * boxScale) - 12
        }
        return 430 * boxScale - 32
    }
    var promptLayout: PromptLayout {
        let width = readingWidth
        return PromptLayout.fit(words: Array(follower.words.dropFirst(follower.position)), maximumWords: chunk,
                                width: width, preferredSize: fontSize, minimumSize: fontSize * minimumFontScale)
    }
    var overlaySize: NSSize {
        if compactOverlay {
            let layout = promptLayout
            let lineHeight = ceil(NSLayoutManager().defaultLineHeight(for: PromptLayout.font(fontSize)))
            // Only the reading width grows. Avoid centering two text lines in a
            // tall square, which places the words far below the camera.
            return NSSize(width: max(54, layout.requiredWidth + 8), height: lineHeight * 2 + 8)
        }
        return NSSize(width: max(readingWidth + 32, promptLayout.requiredWidth + 32), height: max(155, fontSize * 2.5 + 105))
    }
    func resizeOverlay() {
        let size = overlaySize
        for panel in overlays {
            panel.hasShadow = !compactOverlay
            guard panel.frame.size != size else { continue }
            let center = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
            let screen = NSScreen.screens.first { $0.frame.contains(center) } ?? selectedScreen
            let rect = screen.visibleFrame
            let pinnedAtCamera = abs(panel.frame.maxY - (cameraOrigin(screen: screen, size: panel.frame.size).y + panel.frame.height)) < 3
            if pinnedAtCamera {
                let origin = CGPoint(x: min(rect.maxX - size.width, max(rect.minX, center.x - size.width / 2)),
                                     y: cameraOrigin(screen: screen, size: size).y)
                panel.setFrame(NSRect(origin: origin, size: size), display: true)
                continue
            }
            let origin = CGPoint(x: min(rect.maxX - size.width, max(rect.minX, center.x - size.width / 2)),
                                 y: min(rect.maxY - size.height, max(rect.minY, center.y - size.height / 2)))
            panel.setFrame(NSRect(origin: origin, size: size), display: true)
        }
    }
    func configureBoxes() {
        let visible = overlays.contains { $0.isVisible }
        overlays.forEach { $0.close() }; overlays = []; hoveredBoxes = []; visibleBoxCount = 0
        if sevenBoxes { gazeEnabled = false; toggleGaze() }
        if visible || running { showOverlay() }
    }
    func showOverlay() {
        if overlays.isEmpty {
            for index in 0..<(sevenBoxes ? 7 : 1) {
                let panel = OverlayPanel(contentRect: NSRect(origin: .zero, size: overlaySize), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.title = "Prompt \(index + 1)"
                panel.isReleasedWhenClosed = false
                panel.isFloatingPanel = true; panel.level = .floating
                panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = !compactOverlay
                panel.isMovableByWindowBackground = true; panel.hidesOnDeactivate = false
                panel.contentView = NSHostingView(rootView: OverlayView(model: self, boxID: index))
                overlays.append(panel)
            }
            arrangeBoxes()
        }
        overlays.forEach { $0.orderFrontRegardless() }; visibleBoxCount = overlays.filter { $0.isVisible }.count
    }
    func arrangeBoxes() {
        let screen = selectedScreen; trackingScreen = screen
        let rect = screen.visibleFrame
        if sevenBoxes {
            for (index, panel) in overlays.enumerated() {
                if index == 1 {
                    panel.setFrameOrigin(cameraOrigin(screen: screen, size: panel.frame.size))
                } else if index == 6 {
                    panel.setFrameOrigin(CGPoint(x: screen.frame.midX - panel.frame.width / 2,
                                                 y: screen.frame.midY - panel.frame.height / 2))
                } else {
                    let x = [0.12, 0.5, 0.88][index % 3]
                    let y = index < 3 ? cameraOrigin(screen: screen, size: panel.frame.size).y
                        : rect.minY + (rect.height - panel.frame.height) * 0.18
                    panel.setFrameOrigin(CGPoint(x: rect.minX + (rect.width - panel.frame.width) * x, y: y))
                }
            }
        } else { pinNearCamera() }
        smoothed = nil
    }
    func pinNearCamera() {
        if sevenBoxes { arrangeBoxes(); return }
        let screen = selectedScreen; trackingScreen = screen
        overlay?.setFrameOrigin(cameraOrigin(screen: screen, size: overlaySize))
        smoothed = nil
    }
    private func cameraOrigin(screen: NSScreen, size: NSSize) -> CGPoint {
        // AppKit reports the notch exclusion strip even when the menu bar is hidden.
        let top = screen.safeAreaInsets.top > 0
            ? screen.frame.maxY - screen.safeAreaInsets.top : screen.visibleFrame.maxY
        return CGPoint(x: screen.frame.midX - size.width / 2, y: top - 1 - size.height)
    }
    func toggleGaze() {
        if gazeEnabled { gaze.start() }
        else { cancelCalibration(); gaze.stop(); cameraStatus = "Camera off" }
    }
    func beginCalibration() {
        gazeEnabled = true; gaze.start(); calibrated = false
        trackingScreen = selectedScreen
        calibration = GazeCalibration(); calibrationIndex = 0; features = []; stepStart = Date()
        calibrationMessage = "Look at the dot. Each point takes about 1.4 seconds."
        overlays.forEach { $0.orderOut(nil) }; visibleBoxCount = 0
        let panel = NSPanel(contentRect: selectedScreen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.level = .floating; panel.backgroundColor = .black; panel.isOpaque = true
        panel.contentView = NSHostingView(rootView: CalibrationView(model: self))
        calibrationPanel = panel; panel.makeKeyAndOrderFront(nil)
        calibrationTimer?.invalidate()
        calibrationTimer = Timer.scheduledTimer(withTimeInterval: 1.4, repeats: true) { [weak self] _ in self?.nextCalibration() }
    }
    private func nextCalibration() {
        guard features.count >= 4 else { calibrationMessage = "Eyes not clear yet. Face the camera, improve lighting, and look at the dot."; features = []; stepStart = Date(); return }
        let mean = CGPoint(x: features.map(\.x).reduce(0, +) / CGFloat(features.count), y: features.map(\.y).reduce(0, +) / CGFloat(features.count))
        if calibrationIndex == targets.count - 1 {
            let estimate = calibration.map(mean)
            let error = estimate.map { hypot($0.x - 0.5, $0.y - 0.5) } ?? 1
            calibrated = calibration.ready && error < 0.20
            cameraStatus = calibrated ? "Calibration checked • following gaze when reading" : "Gaze check failed. Improve lighting, move closer, keep your head still, and recalibrate."
            cancelCalibration(); return
        }
        calibration.samples.append((mean, targets[calibrationIndex]))
        features = []; stepStart = Date()
        if calibrationIndex == targets.count - 2 {
            guard calibration.fit() else {
                cameraStatus = "Not enough eye movement detected. Move closer to the camera and recalibrate."
                cancelCalibration(); return
            }
            let residual = calibration.samples.map { pair -> CGFloat in
                guard let predicted = calibration.map(pair.0) else { return 1 }
                return hypot(predicted.x - pair.1.x, predicted.y - pair.1.y)
            }.reduce(0, +) / CGFloat(calibration.samples.count)
            guard residual < 0.18 else {
                cameraStatus = "Eye samples were inconsistent. Keep your head steady and recalibrate."
                cancelCalibration(); return
            }
            calibrationMessage = "One quick check: look at the center dot."
        } else { calibrationMessage = "Look at the dot. Each point takes about 1.4 seconds." }
        calibrationIndex += 1
    }
    func cancelCalibration() {
        calibrationTimer?.invalidate(); calibrationTimer = nil
        calibrationPanel?.close(); calibrationPanel = nil
        overlays.forEach { $0.orderFrontRegardless() }; visibleBoxCount = overlays.filter { $0.isVisible }.count
    }
    private func receive(_ feature: CGPoint?) {
        eyesVisible = feature != nil
        guard let feature else { if gazeEnabled && calibrationPanel == nil { cameraStatus = "Eyes not visible • holding prompt position" }; return }
        if calibrationPanel != nil {
            if Date().timeIntervalSince(stepStart) > 0.45 { features.append(feature) }
            return
        }
        guard !sevenBoxes, gazeEnabled, calibrated, running, let mapped = calibration.map(feature), let overlay, let screen = trackingScreen else { return }
        cameraStatus = "Following gaze • drag prompt or pin near camera anytime"
        let rect = screen.visibleFrame
        let calibrationRect = screen.frame
        let desired = CGPoint(x: calibrationRect.minX + min(1, max(0, mapped.x)) * calibrationRect.width, y: calibrationRect.maxY - min(1, max(0, mapped.y)) * calibrationRect.height)
        let previous = smoothed ?? desired
        let point = CGPoint(x: previous.x * 0.65 + desired.x * 0.35, y: previous.y * 0.65 + desired.y * 0.35)
        smoothed = point
        guard Date().timeIntervalSince(lastMovement) > 0.1 else { return }
        let origin = CGPoint(x: min(rect.maxX - overlay.frame.width, max(rect.minX, point.x - overlay.frame.width / 2)), y: min(rect.maxY - overlay.frame.height, max(rect.minY, point.y - overlay.frame.height / 2)))
        guard hypot(origin.x - overlay.frame.minX, origin.y - overlay.frame.minY) > 45 else { return }
        lastMovement = Date()
        overlay.animator().setFrameOrigin(origin)
    }
}
struct EditorView: View {
    @ObservedObject var model: PrompterModel
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Image(systemName: "text.bubble.fill").font(.system(size: 30)).foregroundStyle(.mint)
                VStack(alignment: .leading) { Text("ScriptMax").font(.largeTitle.bold()); Text("Your words. A little closer to the lens.").foregroundStyle(.secondary) }
                Spacer()
            }
            TextEditor(text: $model.script).font(.system(size: 18)).padding(10)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 14))
                .disabled(model.running)
                .onChange(of: model.script) { model.scriptEdited() }
            Text("Advances only on a script match. Repeated phrases can move back to the words you are saying; uncertain speech holds the prompt.").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 24) {
                Stepper("Up to \(model.chunk) words", value: $model.chunk, in: 4...10).onChange(of: model.chunk) { model.resizeOverlay() }.frame(width: 220)
                Text("Largest text")
                Slider(value: $model.fontSize, in: 8...44).onChange(of: model.fontSize) { model.resizeOverlay() }.frame(width: 130)
            }
            HStack {
                Text("Box width")
                Slider(value: $model.boxScale, in: 0.65...2).onChange(of: model.boxScale) { model.resizeOverlay() }.frame(width: 160)
                Text("Showing \(model.promptLayout.wordCount) words. Wider boxes fit more of the next words.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text("Word size range: \(max(8, Int(model.fontSize * model.minimumFontScale)))–\(Int(model.fontSize)) pt")
                Slider(value: $model.minimumFontScale, in: 0.8...1).frame(width: 130)
                Text("Fewer words appear when a line is crowded.").font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Seven prompt boxes", isOn: $model.sevenBoxes).onChange(of: model.sevenBoxes) { model.configureBoxes() }
            Text("\(model.visibleBoxCount) boxes visible. All boxes show the same current words. Drag each box to a comfortable spot; look at any box as you speak.").font(.caption).foregroundStyle(.secondary)
            Toggle("Compact overlay", isOn: $model.compactOverlay).onChange(of: model.compactOverlay) { model.resizeOverlay() }
            HStack {
                Toggle("Follow my gaze", isOn: $model.gazeEnabled).onChange(of: model.gazeEnabled) { model.toggleGaze() }.disabled(model.sevenBoxes)
                Button(model.calibrated ? "Recalibrate eyes" : "Calibrate eyes") { model.beginCalibration() }.disabled(model.sevenBoxes)
                Spacer()
                Button(model.sevenBoxes ? "Arrange seven boxes" : "Pin near camera") { model.showOverlay(); model.pinNearCamera() }
            }
            Text(model.cameraStatus).font(.caption).foregroundStyle(.secondary)
            Text("Gaze mode uses your webcam and a five-point calibration. Keep your head steady. A fixed prompt near the camera usually gives the best eye contact.").font(.callout).foregroundStyle(.secondary)
            Divider()
            HStack {
                Button { model.start() } label: { Label("Start from beginning", systemImage: "play.fill") }.buttonStyle(.borderedProminent).tint(.mint).disabled(model.script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button(model.running ? "Pause" : "Resume") { model.showOverlay(); model.pause() }.disabled(model.follower.words.isEmpty)
                Button("Stop") { model.stop() }
                Spacer()
                Text("\(model.follower.position) / \(model.follower.words.count) words").monospacedDigit().foregroundStyle(.secondary)
            }
            Text(model.status).font(.callout)
            Text(model.transcript.isEmpty ? "Microphone permission is requested when you start. Camera permission is requested for gaze mode. Speech and camera processing stay on this Mac." : "Heard: \(model.transcript)")
                .font(.caption).foregroundStyle(.secondary).lineLimit(2).frame(height: 34, alignment: .topLeading)
        }.padding(28).preferredColorScheme(.dark)
    }
}
struct OverlayView: View {
    @ObservedObject var model: PrompterModel
    let boxID: Int
    var body: some View {
        Group {
            if model.compactOverlay {
                ZStack(alignment: .topTrailing) {
                    VStack(spacing: 2) {
                        ForEach(Array(model.promptLayout.lines.enumerated()), id: \.offset) { _, line in
                            Text(line).font(Font(PromptLayout.font(model.promptLayout.fontSize)))
                                .lineLimit(1).fixedSize().frame(maxWidth: .infinity)
                        }
                    }.padding(.horizontal, 4).padding(.vertical, 3)
                    if model.hoveredBoxes.contains(boxID) {
                        Button { model.pause() } label: { Image(systemName: model.running ? "pause.fill" : "play.fill").font(.system(size: 8)) }
                            .buttonStyle(.plain).padding(5).background(.black.opacity(0.8), in: Circle()).padding(3)
                    }
                }.onHover { inside in
                    if inside { model.hoveredBoxes.insert(boxID) } else { model.hoveredBoxes.remove(boxID) }
                }
                    .help("Drag to move. Hover to pause. Text size and other controls are in ScriptMax.")
            } else {
                VStack(spacing: 10) {
                    HStack {
                        Circle().fill(model.follower.hasConfidentMatch ? Color.mint : Color.orange).frame(width: 6, height: 6)
                        Text(model.running ? (model.follower.hasConfidentMatch ? "MATCHED" : "WAITING FOR MATCH") : "PAUSED").font(.system(size: 9, weight: .semibold, design: .monospaced))
                        Spacer(); Text("\(model.follower.position)/\(model.follower.words.count)").font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    Text(model.promptLayout.lines.joined(separator: "\n"))
                        .font(Font(PromptLayout.font(model.promptLayout.fontSize))).lineLimit(2).fixedSize()
                    Text(model.follower.upcoming(model.promptLayout.wordCount)).font(.system(size: 12)).foregroundStyle(.white.opacity(0.5)).lineLimit(2)
                    HStack(spacing: 18) {
                        Button { model.move(-model.chunk) } label: { Image(systemName: "backward.end.fill") }
                        Button { model.pause() } label: { Image(systemName: model.running ? "pause.fill" : "play.fill") }
                        Button { model.move(model.chunk) } label: { Image(systemName: "forward.end.fill") }
                        Spacer()
                        Button { model.gazeEnabled = false; model.pinNearCamera() } label: { Image(systemName: "pin.fill") }
                        Button { model.stop() } label: { Image(systemName: "xmark") }
                    }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.white.opacity(0.65))
                }.padding(16)
            }
        }.frame(width: model.overlaySize.width, height: model.overlaySize.height, alignment: model.compactOverlay ? .top : .center)
            .background(Color(red: 0.055, green: 0.075, blue: 0.085).opacity(0.94), in: RoundedRectangle(cornerRadius: model.compactOverlay ? 6 : 18))
            .overlay(RoundedRectangle(cornerRadius: model.compactOverlay ? 6 : 18).stroke(.white.opacity(0.12)))
            .foregroundStyle(.white)
    }
}
struct CalibrationView: View {
    @ObservedObject var model: PrompterModel
    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color(red: 0.025, green: 0.04, blue: 0.05)
                VStack(spacing: 12) {
                    Text("Eye calibration • \(min(5, model.calibrationIndex + 1)) of 5 • quick check").font(.title2.bold())
                    Text(model.calibrationMessage).foregroundStyle(.secondary)
                    Text(model.eyesVisible ? "Both eyes detected" : "Move closer until both eyes are detected").foregroundStyle(model.eyesVisible ? Color.mint : Color.orange).font(.callout)
                    Button("Cancel calibration") { model.cancelCalibration() }
                }.position(x: geo.size.width / 2, y: geo.size.height / 2 + 100)
                Circle().fill(.mint).frame(width: 22, height: 22).overlay(Circle().stroke(.white, lineWidth: 2).frame(width: 38, height: 38))
                    .position(x: geo.size.width * model.targets[model.calibrationIndex].x, y: geo.size.height * model.targets[model.calibrationIndex].y)
            }.foregroundStyle(.white)
        }.preferredColorScheme(.dark)
    }
}
