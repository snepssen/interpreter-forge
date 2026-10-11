import InterpreterCore
import InterpreterEngine
import SwiftUI

/// The shared conversation screen, with platform-specific audio controls.
public struct ContentView: View {
    @Bindable var session: LiveSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showEnglish = true
    @State private var managingModels = false

    public init(session: LiveSession) { self.session = session }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            feed
            #if os(macOS)
            Divider()
            listening.padding(16)
            #endif
        }
        .background(InterfaceStyle.canvas)
        #if os(iOS)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 12) {
                Divider()
                listening
                LiveButton(session: session, large: true)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .background(.bar)
        }
        #endif
        .sheet(isPresented: $managingModels) { ModelManager(session: session) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "waveform")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 44, height: 44)
                    .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Interpreter").font(.title2.bold())
                    Text("Translation on this device").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                #if os(macOS)
                LiveButton(session: session)
                #endif
                Button { managingModels = true } label: {
                    Image(systemName: "gearshape")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                        .background(InterfaceStyle.surface, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .help("Download and manage models")
                .accessibilityLabel("Models")
            }
            HStack(spacing: 12) {
                LanguageMenu(languages: $session.languages, disabled: session.isLive || session.isBusy)
                Spacer(minLength: 0)
                SessionStatus(phase: session.phase)
            }
            #if os(macOS)
            HStack(spacing: 16) {
                DevicePicker(title: "Microphone", input: true, selection: $session.microphone)
                DevicePicker(title: "Listen through", input: false, selection: $session.speaker)
            }
            .disabled(session.isLive || session.isBusy)
            #endif
        }
        .padding(16)
        .background(.bar)
    }

    private var feed: some View {
        ScrollViewReader { scroll in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Conversation").font(.headline)
                        Spacer()
                        Menu {
                            Toggle("Show English context", isOn: $showEnglish)
                            Divider()
                            Button("Clear conversation", systemImage: "trash") { session.clear() }
                                .disabled(session.lines.isEmpty || session.isLive)
                        } label: {
                            Image(systemName: "line.3.horizontal.decrease")
                                .frame(width: 44, height: 44)
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("Transcript options")
                        .accessibilityLabel("Transcript options")
                    }
                    if showStatus { placeholder }
                    ForEach(visible) { line in
                        LineView(line: line, isLive: session.isLive).id(line.id)
                    }
                }
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
                .padding(16)
            }
            .onChange(of: session.lines) {
                if let last = visible.last {
                    if reduceMotion { scroll.scrollTo(last.id, anchor: .bottom) }
                    else { withAnimation(.easeOut(duration: 0.2)) { scroll.scrollTo(last.id, anchor: .bottom) } }
                }
            }
        }
    }

    private var visible: [LiveSession.Line] {
        session.lines.filter { showEnglish || ($0.silence != .english && $0.silence != .echo) }
    }

    private var showStatus: Bool {
        switch session.phase {
        case .ready, .live: visible.isEmpty
        default: true
        }
    }

    @ViewBuilder private var placeholder: some View {
        switch session.phase {
        case .choosingModel:
            ModelPicker(session: session)
        case .loading(let what):
            statusPanel(title: "Getting ready", detail: what, symbol: "waveform") {
                ProgressView().controlSize(.regular)
            }
        case .idle:
            statusPanel(title: "Getting ready", detail: "Preparing your interpreter…", symbol: "waveform") {
                ProgressView().controlSize(.regular)
            }
        case .failed(let why):
            statusPanel(title: "Interpreter needs attention", detail: why, symbol: "exclamationmark.triangle") {
                Button("Try again") { Task { await session.prepare() } }
                    .buttonStyle(.borderedProminent).disabled(session.isBusy)
            }
        case .ready:
            statusPanel(title: "Ready to listen", detail: readyDescription, symbol: "headphones") {
                Label("English speech stays quiet and provides context.", systemImage: "text.bubble")
                    .font(.callout).foregroundStyle(.secondary)
                #if os(iOS)
                Text("Keep Interpreter open while listening.")
                    .font(.caption).foregroundStyle(.secondary)
                #endif
            }
        case .live:
            statusPanel(title: "Listening for speech", detail: "English translations will appear here as people speak.", symbol: "waveform") {
                Text("You can stop at any time.").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var readyDescription: String {
        if session.anyLanguage { return "Press Live to hear the conversation in English. Headphones work best." }
        return "Press Live to interpret \(Languages.list(session.languages.filter { $0 != "en" })) into English. Other languages are skipped."
    }

    private func statusPanel<Actions: View>(title: String, detail: String, symbol: String,
                                           @ViewBuilder actions: () -> Actions) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: symbol)
                .font(.largeTitle).foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Text(title).font(.title2.bold())
            Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            actions()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 16)
        .panel()
    }

    private var listening: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 7) {
                Image(systemName: session.isLive ? "mic.fill" : "mic")
                    .foregroundStyle(session.isLive ? Color.accentColor : .secondary)
                LevelMeter(level: session.level).frame(width: 44, height: 5)
            }
            .accessibilityHidden(true)
            if let notice = session.notice {
                Label {
                    Text(notice).foregroundStyle(.primary)
                } icon: {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.isLive ? "Listening" : "Microphone off").fontWeight(.medium)
                    if session.isLive {
                        Text(session.hearing.isEmpty ? "Waiting for speech…" : session.hearing)
                            .foregroundStyle(.secondary).lineLimit(3)
                    } else if let model = session.translationModel {
                        Text(model.name).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(.callout)
    }
}

struct LiveButton: View {
    let session: LiveSession
    var large = false
    private var enabled: Bool { !session.isBusy && (session.phase == .ready || session.isLive) }

    var body: some View {
        Button {
            Task { session.isLive ? session.stop() : await session.start() }
        } label: {
            Label(session.isLive ? "Stop" : "Live", systemImage: session.isLive ? "stop.fill" : "mic.fill")
                .font(.title3.bold())
                .frame(minWidth: large ? 0 : 88, maxWidth: large ? .infinity : nil, minHeight: large ? 54 : 44)
                .padding(.horizontal, 16)
                .foregroundStyle(.white)
                .background(session.isLive ? Color.red : Color.accentColor, in: RoundedRectangle(cornerRadius: 14))
                .opacity(enabled ? 1 : 0.4)
                .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain).disabled(!enabled)
        .keyboardShortcut(.space, modifiers: [])
        .help("Start or stop interpreting (Space)")
        .accessibilityLabel(session.isLive ? "Stop interpreting" : "Start interpreting")
    }
}

struct SessionStatus: View {
    let phase: LiveSession.Phase
    private var title: String {
        switch phase {
        case .live: "Live"
        case .ready: "Ready"
        case .failed: "Needs attention"
        case .choosingModel: "Setup"
        default: "Preparing"
        }
    }
    private var tint: Color {
        switch phase {
        case .live: .green
        case .ready: .accentColor
        case .failed: .orange
        default: .secondary
        }
    }
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(tint).frame(width: 6, height: 6).accessibilityHidden(true)
            Text(title).font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(tint.opacity(0.1), in: Capsule())
        .fixedSize()
        .accessibilityLabel("Status: \(title)")
    }
}

struct LineView: View {
    let line: LiveSession.Line
    var isLive = true

    private var heading: String {
        switch line.silence {
        case .english?: "English context"
        case .echo?: "Echo skipped"
        case .language?: "Outside selected languages"
        case .unclear?: "Please repeat"
        case nil: line.translation == nil ? "Speech" : "English translation"
        }
    }
    private var tint: Color { line.silence == .unclear ? .orange : (line.silence == nil ? .accentColor : .secondary) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(heading).font(.caption.weight(.semibold)).foregroundStyle(tint)
                Spacer(minLength: 8)
                if let lag = line.lag {
                    Text(String(format: "%.1f s", lag)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        .accessibilityLabel(String(format: "Translation delay %.1f seconds", lag))
                }
            }
            switch line.silence {
            case .english?, .echo?, .language?:
                Text(line.source).foregroundStyle(.secondary).textSelection(.enabled)
            case .unclear?:
                Text(line.source).textSelection(.enabled)
                Label {
                    Text(line.translation ?? "Please repeat this piece.").foregroundStyle(.primary)
                } icon: {
                    Image(systemName: "questionmark.circle").foregroundStyle(.orange)
                }
                .font(.callout)
            case nil:
                if let translation = line.translation {
                    Text(translation).font(.title3.weight(.medium)).textSelection(.enabled)
                    Text(line.source).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                } else {
                    Text(line.source).textSelection(.enabled)
                    Text(isLive ? "Interpreting…" : "Session ended before translation")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if line.brief {
                    Text("Shortened to catch up").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(tint: line.silence == nil || line.silence == .unclear ? tint : nil)
    }
}

struct LanguageMenu: View {
    @Binding var languages: [String]
    let disabled: Bool
    static let all = Languages.names.map { (code: $0.key, name: $0.value) }.sorted { $0.name < $1.name }
    private var selected: [String] { languages.filter { $0 != "en" } }
    private var any: Bool { selected.isEmpty }
    private var summary: String {
        if any { return "Any language" }
        if selected.count > 2 { return "\(selected.count) languages" }
        return Languages.list(selected)
    }
    private func binding(_ code: String) -> Binding<Bool> {
        Binding(get: { languages.contains(code) }, set: { on in
            if on && !languages.contains(code) { languages.append(code) }
            else if !on { languages.removeAll { $0 == code } }
        })
    }
    var body: some View {
        Menu {
            Button { languages = ["en"] } label: {
                if any { Label("Any language", systemImage: "checkmark") } else { Text("Any language") }
            }
            Section("Only these languages") {
                ForEach(Self.all.filter { $0.code != "en" }, id: \.code) { language in
                    Toggle(language.name, isOn: binding(language.code))
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "globe")
                Text(summary + " → English").lineLimit(2)
            }
            .font(.callout.weight(.medium))
            .frame(minHeight: 44, alignment: .leading)
        }
        .menuStyle(.borderlessButton)
        #if os(macOS)
        .fixedSize()
        #endif
        .disabled(disabled)
        .help("Choose the languages spoken here. Other languages are skipped.")
        .accessibilityLabel("Spoken languages")
        .accessibilityValue(any ? "Any language into English" : Languages.list(selected) + " into English")
    }
}

#if os(macOS)
struct DevicePicker: View {
    let title: String
    let input: Bool
    @Binding var selection: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: input ? "mic" : "headphones").font(.caption).foregroundStyle(.secondary)
            Picker(title, selection: $selection) {
                Text("System default").tag(String?.none)
                ForEach(AudioDevices.all().filter { input ? $0.isInput : $0.isOutput }) { device in
                    Text(device.name).tag(Optional(device.name))
                }
            }
            .labelsHidden().controlSize(.regular).accessibilityLabel(title)
        }
        .frame(maxWidth: .infinity)
    }
}
#endif

struct LevelMeter: View {
    let level: Float
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.15))
                Capsule().fill(Color.accentColor)
                    .frame(width: geometry.size.width * CGFloat(min(1, sqrt(Double(level)) * 3)))
            }
        }
    }
}
