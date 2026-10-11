import InterpreterEngine
import InterpreterUI
import SwiftUI

@main
struct InterpreterApp: App {
    @State private var session = LiveSession()

    var body: some Scene {
        WindowGroup("Interpreter") {
            InterpreterWindow(session: session)
        }
        .defaultSize(width: 780, height: 720)
        .windowResizability(.contentMinSize)
    }
}

private struct InterpreterWindow: View {
    let session: LiveSession
    @State private var id = UUID()

    var body: some View {
        ContentView(session: session)
            .frame(minWidth: 520, minHeight: 560)
            .onAppear { session.windowOpened(id) }
            .onDisappear { session.windowClosed(id) }
            .task { await session.prepare() }
    }
}
