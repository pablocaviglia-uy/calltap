import AppKit
import SwiftUI

@main
struct CallTapApp: App {
    @StateObject private var recorder = RecordingController()
    @StateObject private var loginItem = LoginItem()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(recorder: recorder, loginItem: loginItem)
        } label: {
            Image(systemName: recorder.menuBarSymbol)
        }
        .menuBarExtraStyle(.menu)
    }
}

private struct MenuContent: View {
    @ObservedObject var recorder: RecordingController
    @ObservedObject var loginItem: LoginItem

    var body: some View {
        Text(recorder.statusLine)
        if let input = recorder.inputDeviceName {
            Text("Your voice from: \(input)")
        }
        if recorder.inputIsBluetooth {
            Text("Tip: pick the Mac's microphone in Sound settings to keep call quality")
        }
        if let notice = recorder.notice {
            Text(notice)
        }
        Divider()
        if recorder.recording != nil {
            Button("Stop Recording") { recorder.stopRecording() }
        } else {
            Button(recorder.callActive ? "Record This Call" : "Record WhatsApp Audio") { recorder.startRecording() }
                .disabled(recorder.isSaving)
        }
        if recorder.lastSaved != nil {
            Button("Show Last Recording") { recorder.showLastRecording() }
        }
        Button("Open Recordings Folder") { recorder.openRecordingsFolder() }
        Divider()
        Toggle("Open at Login", isOn: Binding(
            get: { loginItem.isEnabled },
            set: { loginItem.set($0) }
        ))
        if loginItem.needsApproval {
            Button("Allow CallTap in Login Items…") { loginItem.openSystemSettings() }
        }
        if let error = loginItem.error {
            Text("Login item: \(error)")
        }
        Button("Quit CallTap") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}

extension RecordingController {
    var menuBarSymbol: String {
        if recording != nil { return "record.circle.fill" }
        return callActive ? "phone.badge.waveform" : "phone.and.waveform"
    }

    var statusLine: String {
        if let recording {
            return "Recording since \(recording.startedAt.formatted(date: .omitted, time: .shortened))"
        }
        if isSaving { return "Saving recording…" }
        return callActive ? "WhatsApp call in progress" : "No WhatsApp call"
    }
}
