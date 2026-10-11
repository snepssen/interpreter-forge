import InterpreterEngine
import InterpreterUI
import SwiftUI

@main
struct InterpreterPhoneApp: App {
    @State private var session = LiveSession()

    var body: some Scene {
        WindowGroup {
            ContentView(session: session)
                .task { await session.prepare() }
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
