import AppKit
import CoreAudio
import SwiftUI

@main
struct CallTapApp: App {
    @StateObject private var recorder = RecordingController()
    @StateObject private var devices = AudioDevicesController()
    @StateObject private var meters = LevelMeters()
    @StateObject private var loginItem = LoginItem()

    var body: some Scene {
        MenuBarExtra {
            Panel(recorder: recorder, devices: devices, meters: meters, loginItem: loginItem)
        } label: {
            Image(systemName: recorder.menuBarSymbol)
        }
        // A panel rather than a menu: menus cannot hold volume sliders.
        .menuBarExtraStyle(.window)
    }
}

private struct Panel: View {
    @ObservedObject var recorder: RecordingController
    @ObservedObject var devices: AudioDevicesController
    @ObservedObject var meters: LevelMeters
    @ObservedObject var loginItem: LoginItem

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("CallTap").font(.headline)
                Spacer()
                Text(recorder.statusLine).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Divider()
            DeviceSection(title: "Output", direction: .output, devices: devices, level: meters.output, levelNote: nil)
            DeviceSection(title: "Input", direction: .input, devices: devices, level: meters.input,
                          levelNote: meters.inputNote)
            if let error = devices.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            Divider()
            RecordSection(recorder: recorder)
            Divider()
            Footer(recorder: recorder, loginItem: loginItem)
        }
        .padding(14)
        .frame(width: 330)
        .background(WindowVisibility { visible in
            if visible { meters.start(input: devices.input.selected) } else { meters.stop() }
        })
        .onChange(of: devices.input.selected) { _, selected in
            meters.setInput(selected)
        }
    }
}

private struct DeviceSection: View {
    let title: String
    let direction: AudioDirection
    @ObservedObject var devices: AudioDevicesController
    let level: Float
    let levelNote: String?

    var body: some View {
        let side = devices.side(direction)
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Picker(title, selection: Binding(
                get: { side.selected?.id ?? AudioObjectID(kAudioObjectUnknown) },
                set: { devices.select($0, for: direction) }
            )) {
                ForEach(side.devices) { device in
                    Label(device.name, systemImage: device.symbol(for: direction)).tag(device.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)

            HStack(spacing: 8) {
                Button {
                    devices.toggleMute(for: direction)
                } label: {
                    Image(systemName: muteSymbol(side)).frame(width: 18)
                }
                .buttonStyle(.borderless)
                .disabled(side.muted == nil)
                .help(side.muted == true ? "Unmute" : "Mute")

                if let volume = side.volume {
                    Slider(value: Binding(
                        get: { Double(volume) },
                        set: { devices.setVolume(Float($0), for: direction) }
                    ), in: 0...1)
                } else {
                    Text("This device has no adjustable volume").font(.caption).foregroundStyle(.secondary)
                }
            }

            if let levelNote {
                Text(levelNote).font(.caption2).foregroundStyle(.secondary)
            } else {
                LevelBar(level: level).padding(.leading, 26)
            }

            if direction == .input, side.selected?.isBluetooth == true {
                Label("Headset microphone: puts the headset in hands-free mode and lowers call quality",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func muteSymbol(_ side: AudioDevicesController.Side) -> String {
        if direction == .input { return side.muted == true ? "mic.slash" : "mic" }
        if side.muted == true { return "speaker.slash" }
        guard let volume = side.volume else { return "speaker" }
        return volume < 0.01 ? "speaker" : volume < 0.34 ? "speaker.wave.1" : volume < 0.67 ? "speaker.wave.2" : "speaker.wave.3"
    }
}

private struct RecordSection: View {
    @ObservedObject var recorder: RecordingController

    /// Says why a call recording uses this microphone when it is not the Mac's input.
    private func voiceSource(_ microphone: MicrophoneSelector.Device) -> String {
        if let recording = recorder.recording, case .call(let app) = recording.source,
           recorder.callMicrophone?.id == microphone.id {
            return "Your voice from \(microphone.name), the microphone \(app.name) uses"
        }
        return "Your voice from \(microphone.name)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Record").font(.caption).foregroundStyle(.secondary)
            if let call = recorder.activeCall, let microphone = recorder.callMicrophone, microphone.isBluetooth {
                Label("\(call.name) is using the \(microphone.name) microphone, which puts the headset in hands-free mode and lowers call quality. Choose the Mac's microphone in \(call.name)'s audio settings.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if recorder.recording != nil {
                HStack {
                    Image(systemName: "record.circle.fill").foregroundStyle(.red)
                    if let microphone = recorder.recording?.microphone {
                        Text(voiceSource(microphone)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Stop") { recorder.stop() }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                }
            } else {
                if let call = recorder.activeCall {
                    Button {
                        recorder.recordCall()
                    } label: {
                        Label("Record \(call.name) Call", systemImage: "phone.badge.waveform")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(recorder.activity != nil)
                }
                HStack {
                    Button {
                        recorder.recordEverything()
                    } label: {
                        Label("Everything", systemImage: "speaker.wave.2")
                    }
                    Menu {
                        if recorder.playingApps.isEmpty {
                            Text("No app is playing audio")
                        }
                        ForEach(recorder.playingApps, id: \.bundleID) { app in
                            Button(app.name) { recorder.record(app) }
                        }
                    } label: {
                        Label("An App", systemImage: "app.badge")
                    }
                    .fixedSize()
                }
                .disabled(recorder.activity != nil)
            }

            Toggle("Include my voice (always on in calls)", isOn: $recorder.includeMicrophone)
                .toggleStyle(.checkbox)
            if TranscriptionLanguage.isSupported {
                Picker("Transcription", selection: $recorder.transcription) {
                    ForEach(TranscriptionLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
            }
            if let notice = recorder.notice {
                Text(notice).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct Footer: View {
    @ObservedObject var recorder: RecordingController
    @ObservedObject var loginItem: LoginItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("Recordings") { recorder.openRecordingsFolder() }
                if recorder.lastSaved != nil {
                    Button("Last Recording") { recorder.showLastRecording() }
                }
                if recorder.lastTranscript != nil {
                    Button("Transcript") { recorder.openLastTranscript() }
                }
            }
            HStack {
                Toggle("Open at Login", isOn: Binding(
                    get: { loginItem.isEnabled },
                    set: { loginItem.set($0) }
                ))
                .toggleStyle(.checkbox)
                if loginItem.needsApproval {
                    Button("Allow…") { loginItem.openSystemSettings() }
                }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            if let error = loginItem.error {
                Text("Login item: \(error)").font(.caption).foregroundStyle(.red)
            }
        }
        .controlSize(.small)
    }
}

extension RecordingController {
    var menuBarSymbol: String {
        if recording != nil { return "record.circle.fill" }
        if activity != nil { return "waveform.circle" }
        return activeCall != nil ? "phone.badge.waveform" : "phone.and.waveform"
    }

    var statusLine: String {
        if let recording {
            let time = recording.startedAt.formatted(date: .omitted, time: .shortened)
            return "Recording \(recording.source.title) since \(time)"
        }
        if let activity { return activity }
        if let call = activeCall { return "\(call.name) call in progress" }
        return "Ready"
    }
}
