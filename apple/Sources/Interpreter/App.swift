import InterpreterEngine
import SwiftUI

@main
struct InterpreterApp: App {
    @State private var session = LiveSession()

    var body: some Scene {
        WindowGroup("Interpreter") {
            ContentView(session: session)
                .frame(minWidth: 480, minHeight: 560)
                .task { await session.prepare() }
        }
        .windowResizability(.contentMinSize)
    }
}
