import XCTest
@testable import CallTapCore

/// Bundle IDs below are the ones Core Audio listed on a real Mac.
final class AudioAppsTests: XCTestCase {
    private let apps = [
        RunningApp(bundleID: "com.google.Chrome", name: "Google Chrome"),
        RunningApp(bundleID: "com.spotify.client", name: "Spotify"),
        RunningApp(bundleID: "com.microsoft.teams2", name: "Microsoft Teams"),
        RunningApp(bundleID: "io.github.pablocaviglia-uy.calltap", name: "CallTap"),
    ]

    private func process(_ id: UInt32, _ bundle: String, input: Bool = false, output: Bool = false) -> AudioProcessInfo {
        AudioProcessInfo(objectID: id, bundleID: bundle, isRunningInput: input, isRunningOutput: output)
    }

    func testHelpersBelongToTheirApp() {
        XCTAssertEqual(AudioApps.owner(of: "com.google.Chrome.helper", among: apps)?.name, "Google Chrome")
        XCTAssertEqual(AudioApps.owner(of: "com.microsoft.teams2.modulehost", among: apps)?.name, "Microsoft Teams")
        XCTAssertNil(AudioApps.owner(of: "com.apple.avconferenced", among: apps))
        // A shared prefix that is not a dotted component does not count.
        XCTAssertNil(AudioApps.owner(of: "com.google.ChromeRemoteDesktop", among: apps))
    }

    func testOnlyAppsPlayingAudioAreListedWithAllTheirProcesses() {
        let groups = AudioApps.playing(processes: [
            process(1, "com.google.Chrome"),
            process(2, "com.google.Chrome.helper", output: true),
            process(3, "com.spotify.client"),
            process(4, "com.apple.mediaremoted", output: true),
            process(5, "io.github.pablocaviglia-uy.calltap", output: true),
        ], apps: apps, excluded: ["io.github.pablocaviglia-uy.calltap"])
        XCTAssertEqual(groups, [AudioAppGroup(bundleID: "com.google.Chrome", name: "Google Chrome", processes: [1, 2])])
    }

    func testCallIsActiveWhileTheAppCapturesInput() {
        let idle = [process(10, "net.whatsapp.WhatsApp", output: true)]
        XCTAssertNil(CallApp.activeCall(in: idle))

        let call = [process(10, "net.whatsapp.WhatsApp", input: true, output: true),
                    process(11, "net.whatsapp.WhatsApp.ServiceExtension")]
        XCTAssertEqual(CallApp.activeCall(in: call)?.app, .whatsApp)
        XCTAssertEqual(CallApp.activeCall(in: call)?.processes, [10, 11])
    }

    func testFaceTimeAudioRunsInAvconferenced() {
        let call = [process(20, "com.apple.avconferenced", input: true)]
        XCTAssertEqual(CallApp.activeCall(in: call)?.app, .faceTime)
    }

    func testTeamsHelpersCount() {
        let call = [process(30, "com.microsoft.teams2.modulehost", input: true)]
        XCTAssertEqual(CallApp.activeCall(in: call)?.app, .teams)
    }
}
