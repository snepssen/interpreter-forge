import InterpreterCore
import InterpreterEngine
import SwiftUI

/// The whole app, on a Mac or an iPhone: what is said, translated, as it comes.
public struct ContentView: View {
    @Bindable var session: LiveSession
    @State private var showEnglish = true
    @State private var managingModels = false

    public init(session: LiveSession) { self.session = session }

    public var body: some View {
        main
            .sheet(isPresented: $managingModels) { ModelManager(session: session) }
    }

    @ViewBuilder private var main: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            controls
            Divider()
            feed
            Divider()
            listening
        }
        .background(Color(nsColor: .textBackgroundColor))
        #else
        VStack(spacing: 0) {
            // The gear first in priority: the language menu gives way, truncating,
            // rather than pushing the controls off a phone-width screen.
            HStack(spacing: 12) {
                LanguageMenu(languages: $session.languages, disabled: session.isLive)
                    .layoutPriority(-1)
                Spacer(minLength: 0)
                Toggle(isOn: $showEnglish) { Text("EN").font(.caption.bold()) }
                    .fixedSize()
                    .accessibilityLabel("Show English")
                modelsButton.font(.title3)
            }
            .font(.subheadline)
            .padding(.horizontal, 16).padding(.vertical, 10)
            Divider()
            feed
            Divider()
            listening
            LiveButton(session: session, large: true)
                .padding(.horizontal, 16).padding(.bottom, 12)
        }
        #endif
    }

    // MARK: top

    #if os(macOS)
    private var controls: some View {
        HStack(spacing: 14) {
            LiveButton(session: session)
            VStack(alignment: .leading, spacing: 6) {
                LanguageMenu(languages: $session.languages, disabled: session.isLive)
                HStack(spacing: 8) {
                    DevicePicker(title: "Mic", input: true, selection: $session.microphone)
                    DevicePicker(title: "Out", input: false, selection: $session.speaker)
                }
                .disabled(session.isLive)
            }
            Spacer()
            Toggle("English", isOn: $showEnglish)
                .toggleStyle(.switch).controlSize(.small)
                .help("Show what was said in English, kept as context and not spoken")
            modelsButton
        }
        .padding(14)
    }
    #endif

    private var modelsButton: some View {
        Button { managingModels = true } label: { Image(systemName: "gearshape") }
            .buttonStyle(.borderless)
            .help("Models: download, switch, delete")
            .accessibilityLabel("Models")
    }

    // MARK: middle

    private var feed: some View {
        ScrollViewReader { scroll in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if showStatus { placeholder }
                    ForEach(visible) { line in
                        LineView(line: line).id(line.id)
                    }
                }
                .padding(16)
            }
            .onChange(of: session.lines) {
                if let last = visible.last { withAnimation(.easeOut(duration: 0.2)) { scroll.scrollTo(last.id, anchor: .bottom) } }
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
        VStack(alignment: .leading, spacing: 8) {
            switch session.phase {
            case .choosingModel:
                ModelPicker(session: session)
            case .loading(let what):
                ProgressView().controlSize(.small)
                Text(what).foregroundStyle(.secondary)
            case .failed(let why):
                Label(why, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                Button("Try again") { Task { await session.prepare() } }
            case .ready:
                Text("Press Live and put your headphones in.").font(.title3)
                Text(session.anyLanguage
                     ? "Speech in any language is interpreted into English as it comes; English is left alone."
                     : "Speech in \(Languages.list(session.languages.filter { $0 != "en" })) is interpreted into English as it comes; English is left alone, anything else is taken as misheard.")
                    .foregroundStyle(.secondary)
            default:
                Text("Listening…").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 40)
    }

    // MARK: bottom

    private var listening: some View {
        HStack(spacing: 12) {
            LevelMeter(level: session.level).frame(width: 70, height: 6)
            if let notice = session.notice, !session.isLive {
                Label(notice, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(session.hearing.isEmpty ? (session.isLive ? "Listening" : " ") : session.hearing)
                    .lineLimit(1).truncationMode(.head)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let notice = session.notice {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).help(notice)
                }
            }
            if !session.lines.isEmpty && !session.isLive {
                Button("Clear") { session.clear() }.buttonStyle(.borderless)
            }
        }
        .font(.callout)
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}

/// The one control that matters.
struct LiveButton: View {
    let session: LiveSession
    var large = false

    var body: some View {
        Button {
            Task { session.isLive ? session.stop() : await session.start() }
        } label: {
            HStack(spacing: 8) {
                Circle().fill(session.isLive ? Color.red : Color.secondary.opacity(0.5)).frame(width: 12, height: 12)
                Text(session.isLive ? "Stop" : "Live").font(large ? .title3.bold() : .headline)
            }
            .frame(maxWidth: large ? .infinity : nil)
            .padding(.horizontal, 18).padding(.vertical, large ? 16 : 10)
            .background(session.isLive ? Color.red.opacity(0.12) : Color.accentColor.opacity(0.12), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(session.isBusy || !(session.phase == .ready || session.isLive))
        .keyboardShortcut(.space, modifiers: [])
        .help("Start or stop interpreting (Space)")
    }
}

struct LineView: View {
    let line: LiveSession.Line

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch line.silence {
            case .english?, .echo?:
                Text(line.source).foregroundStyle(.secondary)
            case .language?:
                Text(line.source).foregroundStyle(.tertiary).strikethrough()
                    .help("Not in any language expected here: taken as misheard, not spoken")
            case .unclear?:
                Text(line.source).foregroundStyle(.secondary).textSelection(.enabled)
                Label(line.translation ?? "Please repeat this piece.", systemImage: "questionmark.circle")
                    .font(.callout).foregroundStyle(.orange)
            case nil:
                if let translation = line.translation {
                    Text(translation).font(.title3).textSelection(.enabled)
                } else {
                    Text("…").font(.title3).foregroundStyle(.tertiary)
                }
                HStack(spacing: 6) {
                    Text(line.source).foregroundStyle(.secondary).textSelection(.enabled)
                    if let lag = line.lag {
                        Text(String(format: "%.1f s", lag)).monospacedDigit().foregroundStyle(.tertiary)
                    }
                    if line.brief { Text("brief").foregroundStyle(.tertiary) }
                }
                .font(.callout)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct LanguageMenu: View {
    @Binding var languages: [String]
    let disabled: Bool

    static let all: [(code: String, name: String)] =
        Languages.names.map { (code: $0.key, name: $0.value) }.sorted { $0.name < $1.name }

    private var any: Bool { !languages.contains { $0 != "en" } }

    private func binding(_ code: String) -> Binding<Bool> {
        Binding(get: { languages.contains(code) },
                set: { on in
                    if on {
                        languages.append(code)
                    } else if code != "en" {
                        languages.removeAll { $0 == code }
                    }
                })
    }

    var body: some View {
        Menu {
            Button {
                languages = ["en"]
            } label: {
                if any { Label("Any language", systemImage: "checkmark") } else { Text("Any language") }
            }
            Section("Only these") {
                ForEach(Self.all.filter { $0.code != "en" }, id: \.code) { language in
                    Toggle(language.name, isOn: binding(language.code))
                }
            }
        } label: {
            Text(Languages.list(languages.filter { $0 != "en" }).ifEmpty("Any language") + " → English")
        }
        #if os(macOS)
        .menuStyle(.borderlessButton)
        .fixedSize()
        #else
        .lineLimit(1)
        #endif
        .disabled(disabled)
        .help("Any language by default. Name the languages spoken here to treat anything else as misheard.")
    }
}

#if os(macOS)
struct DevicePicker: View {
    let title: String
    let input: Bool
    @Binding var selection: String?

    var body: some View {
        Picker(title, selection: $selection) {
            Text("System").tag(String?.none)
            ForEach(AudioDevices.all().filter { input ? $0.isInput : $0.isOutput }) { device in
                Text(device.name).tag(Optional(device.name))
            }
        }
        .controlSize(.small).fixedSize()
    }
}
#endif

struct LevelMeter: View {
    let level: Float

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule().fill(Color.green.opacity(0.8))
                    .frame(width: geometry.size.width * CGFloat(min(1, sqrt(Double(level)) * 3)))
            }
        }
    }
}

extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
