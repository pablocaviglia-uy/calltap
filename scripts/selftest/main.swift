// Capture self-test: plays a 1 kHz tone with afplay, records it through CallTap's own process
// tap while recording a microphone, and checks that the tap file keeps the tone's pitch and the
// recording's length. Pins the fix for recordings that played 3× too fast: the tap must not be
// labelled with a rate other than the one its aggregate device runs at, even when a Bluetooth
// headset drops to 16 kHz because its microphone opened.
//
// It also checks the microphone track: switching microphones halfway (when a second name is
// given) must keep one file at 48 kHz that lasts as long as the recording.
//
// Built and run by scripts/capture-selftest.sh.
// Arguments: <work dir> <microphone name fragment> [microphone to switch to halfway].
import AVFoundation
import CoreAudio

setvbuf(stdout, nil, _IOLBF, 0)
let directory = URL(fileURLWithPath: CommandLine.arguments[1])
let microphoneName = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "MacBook"
let switchName = CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : nil
let seconds = 3.0
let toneHz = 1000.0

func writeTone(to url: URL) throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    let frames = AVAudioFrameCount(48_000 * (seconds + 3))
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    for i in 0..<Int(frames) {
        buffer.floatChannelData![0][i] = 0.3 * Float(sin(2 * .pi * toneHz * Double(i) / 48_000))
    }
    try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
}

func microphone(named fragment: String) -> AudioObjectID? {
    let devices = (try? CoreAudioProperty.objectList(CoreAudioProperty.system, kAudioHardwarePropertyDevices)) ?? []
    return devices.first { id in
        let name = ((try? CoreAudioProperty.string(id, kAudioObjectPropertyName)) ?? nil) ?? ""
        let inputs = (try? CoreAudioProperty.objectList(id, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)) ?? []
        return name.localizedCaseInsensitiveContains(fragment) && !inputs.isEmpty
    }
}

/// Seconds of audio in the file, and the tone frequency: the median of zero-crossing estimates
/// over 0.1 s windows that carry the tone. Silent windows are skipped (the tap records silence
/// while macOS shows a permission prompt), and the median ignores the few windows cut by a
/// headset switching profiles. A wrong sample-rate label would move every window — by 3× for
/// 16 kHz audio labelled 48 kHz — so the median still catches it.
func measure(_ url: URL) throws -> (duration: Double, frequency: Double) {
    let file = try AVAudioFile(forReading: url)
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buffer)
    let rate = file.processingFormat.sampleRate
    let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    let size = Int(rate / 10)
    var estimates: [Double] = []
    for start in stride(from: 0, to: samples.count - size, by: size) {
        let window = samples[start..<start + size]
        guard window.map(abs).max() ?? 0 > 0.1 else { continue }
        let crossings = zip(window, window.dropFirst()).filter { ($0 < 0) != ($1 < 0) }.count
        estimates.append(Double(crossings) / 2 / 0.1)
    }
    let sorted = estimates.sorted()
    return (Double(file.length) / rate, sorted.isEmpty ? 0 : sorted[sorted.count / 2])
}

do {
    let tone = directory.appendingPathComponent("tone.caf")
    try writeTone(to: tone)
    let player = Process()
    player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
    player.arguments = [tone.path]
    try player.run()
    defer { player.terminate() }
    Thread.sleep(forTimeInterval: 0.7)
    guard let process = CoreAudioProperty.processObject(for: player.processIdentifier) else {
        print("FAIL afplay has no audio process object"); exit(1)
    }

    let tap = ProcessTapRecorder()
    let mic = MicrophoneRecorder()
    let tapURL = directory.appendingPathComponent("tap.caf")
    let micURL = directory.appendingPathComponent("mic.caf")
    let name: (AudioObjectID) -> String = { ((try? CoreAudioProperty.string($0, kAudioObjectPropertyName)) ?? nil) ?? "?" }
    guard let firstMicrophone = microphone(named: microphoneName) else { print("FAIL no microphone named \(microphoneName)"); exit(1) }
    try mic.prepare(writingTo: micURL)
    let micStarted = Date()
    try mic.use(firstMicrophone)
    print("microphone:", name(firstMicrophone))
    try tap.start(.processes([process]), writingTo: tapURL)
    let started = Date()
    if let switchName {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds / 2))
        guard let second = microphone(named: switchName) else { print("FAIL no microphone named \(switchName)"); exit(1) }
        try mic.use(second)
        print("switched to:", name(second))
        RunLoop.main.run(until: started.addingTimeInterval(seconds))
    } else {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }
    let micFirstAudio = mic.firstBufferAt
    tap.stop()
    mic.stop()
    let stopped = Date()
    let elapsed = stopped.timeIntervalSince(started)
    // Permission prompts delay both the tap's start and the microphone's first audio, so the
    // microphone track is measured from its first buffer — the same point Recording aligns on.
    let micElapsed = stopped.timeIntervalSince(micFirstAudio ?? micStarted)

    let result = try measure(tapURL)
    print(String(format: "recorded %.2f s; tap file %.2f s; tone %.0f Hz", elapsed, result.duration, result.frequency))
    let micFile = try AVAudioFile(forReading: micURL)
    let micDuration = Double(micFile.length) / micFile.fileFormat.sampleRate
    print(String(format: "microphone ran %.2f s; file %.0f Hz, %.2f s", micElapsed, micFile.fileFormat.sampleRate, micDuration))
    let durationOK = abs(result.duration - elapsed) < 0.25
    let pitchOK = abs(result.frequency - toneHz) < 20
    let microphoneOK = micFile.fileFormat.sampleRate == 48_000 && abs(micDuration - micElapsed) < 0.3
    let passed = durationOK && pitchOK && microphoneOK
    print(passed ? "PASS" : "FAIL")
    exit(passed ? 0 : 1)
} catch {
    print("FAIL", error)
    exit(1)
}
