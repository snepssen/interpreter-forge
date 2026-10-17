import InterpreterEngine
import InterpreterUI
import SwiftUI

@main
struct InterpreterPhoneApp: App {
    @State private var session = LiveSession()

    init() { PhoneAudio.prepare() }

    /// `INTERPRETER_DEMO=name.wav` in the launch environment: a file in the
    /// app's Documents, put there with `xcrun devicectl device copy to`,
    /// played in silently as the microphone (iOS/demo-ipad.sh).
    private static var demo: URL? {
        guard let name = ProcessInfo.processInfo.environment["INTERPRETER_DEMO"], !name.isEmpty,
              let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        else { return nil }
        return documents.appending(path: name)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(session: session)
                .task {
                    if let demo = Self.demo { session.useDemoRecording(at: demo) }
                    await session.prepare()
                    // No one to press Live: once ready and not still preparing (becoming
                    // active prepares too), start it.
                    if session.demoRecording != nil {
                        while session.phase != .ready || session.isBusy { try? await Task.sleep(for: .milliseconds(500)) }
                        await session.start()
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
                    session.setActive(false)
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                    session.setActive(true)
                    Task { await session.prepare() }
                }
        }
    }
}
