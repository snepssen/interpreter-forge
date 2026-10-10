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
        }
    }
}
