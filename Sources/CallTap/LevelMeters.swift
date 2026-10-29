import Accelerate
import AppKit
import AVFoundation
import CallTapCore
import CoreAudio
import SwiftUI

/// Output and input level bars for the panel. They listen only while the panel is on screen:
/// metering means capturing, and macOS shows its microphone and audio-recording indicators
/// while it happens.
final class LevelMeters: ObservableObject {
    @Published private(set) var output: Float = 0
    @Published private(set) var input: Float = 0
    /// Why the input bar is off, when it is.
    @Published private(set) var inputNote: String?

    private let outputTap = ProcessTap(label: "calltap.meter-output")
    private let inputCapture = InputCapture(label: "calltap.meter-input")
    private let lock = NSLock()
    private var outputPeak: Float = 0
    private var inputPeak: Float = 0
    private var running = false
    private var inputDevice: AudioObjectID?
    private var timer: Timer?

    func start(input device: AudioDevice?) {
        guard !running else {
            setInput(device)
            return
        }
        running = true
        let own = CoreAudioProperty.processObject(for: getpid()).map { [$0] } ?? []
        try? outputTap.start(.everything(excluding: own)) { [weak self] buffer in
            self?.store(Self.peak(of: buffer), output: true)
        }
        setInput(device)
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in self?.tick() }
    }

    func setInput(_ device: AudioDevice?) {
        guard running, device?.id != inputDevice || device == nil else { return }
        inputCapture.stop()
        inputDevice = nil
        input = 0
        guard let device else {
            inputNote = nil
            return
        }
        // Opening an idle headset microphone would switch the headset to hands-free mode.
        if device.isBluetooth, !MicrophoneSelector.isRunningSomewhere(device.id) {
            inputNote = "Off for headset microphones that are not in use, to keep audio quality"
            return
        }
        do {
            try inputCapture.start(device: device.id) { [weak self] buffer in
                self?.store(Self.peak(of: buffer), output: false)
            }
            inputDevice = device.id
            inputNote = nil
        } catch {
            inputNote = "Input level unavailable"
        }
    }

    func stop() {
        guard running else { return }
        running = false
        timer?.invalidate()
        timer = nil
        outputTap.stop()
        inputCapture.stop()
        inputDevice = nil
        output = 0
        input = 0
    }

    private func store(_ peak: Float, output: Bool) {
        lock.lock()
        if output { outputPeak = max(outputPeak, peak) } else { inputPeak = max(inputPeak, peak) }
        lock.unlock()
    }

    private func tick() {
        lock.lock()
        let (o, i) = (outputPeak, inputPeak)
        outputPeak = 0
        inputPeak = 0
        lock.unlock()
        output = LevelScale.next(displayed: output, incoming: LevelScale.position(peak: o))
        input = LevelScale.next(displayed: input, incoming: LevelScale.position(peak: i))
    }

    /// Peak magnitude across every sample and channel of a float buffer.
    private static func peak(of buffer: AVAudioPCMBuffer) -> Float {
        guard buffer.format.commonFormat == .pcmFormatFloat32 else { return 0 }
        var peak: Float = 0
        for audioBuffer in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList)) {
            guard let data = audioBuffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            var bufferPeak: Float = 0
            vDSP_maxmgv(data, 1, &bufferPeak, vDSP_Length(Int(audioBuffer.mDataByteSize) / MemoryLayout<Float>.size))
            peak = max(peak, bufferPeak)
        }
        return peak
    }
}

/// A horizontal level bar: green, then yellow from -12 dBFS, red from -3 dBFS.
struct LevelBar: View {
    let level: Float

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.18))
                LinearGradient(stops: [.init(color: .green, location: 0),
                                       .init(color: .green, location: 0.78),
                                       .init(color: .yellow, location: 0.82),
                                       .init(color: .red, location: 0.97)],
                               startPoint: .leading, endPoint: .trailing)
                    .mask(alignment: .leading) {
                        Rectangle().frame(width: geometry.size.width * CGFloat(level))
                    }
                    .clipShape(Capsule())
            }
        }
        .frame(height: 5)
        .animation(.linear(duration: 0.05), value: level)
        .accessibilityLabel("Level")
        .accessibilityValue("\(Int(level * 100)) percent")
    }
}

/// Reports whether the hosting window is on screen. A menu bar panel keeps its views alive while
/// closed, so onAppear/onDisappear alone do not say when it is visible.
struct WindowVisibility: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = VisibilityView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? VisibilityView)?.onChange = onChange
    }

    final class VisibilityView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []
        private var lastReported: Bool?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else {
                report(false)
                return
            }
            // A menu bar panel's window exists before it is first shown, and an ordered-out
            // window can still claim to be unoccluded; only isVisible plus occlusion says it is
            // really on screen.
            let names: [Notification.Name] = [NSWindow.didChangeOcclusionStateNotification,
                                              NSWindow.didBecomeKeyNotification,
                                              NSWindow.didResignKeyNotification,
                                              NSWindow.willCloseNotification]
            observers = names.map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                    let closing = note.name == NSWindow.willCloseNotification
                    self?.report(!closing && window.isVisible && window.occlusionState.contains(.visible))
                }
            }
            report(window.isVisible && window.occlusionState.contains(.visible))
        }

        private func report(_ visible: Bool) {
            guard visible != lastReported else { return }
            lastReported = visible
            onChange?(visible)
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }
    }
}
