import Combine
import InterpreterCore
import InterpreterEngine
import SwiftUI
#if os(iOS)
import AVFoundation
import UIKit
#endif

/// The shared conversation screen. Mostly it isn't looked at: the English is in
/// the headphones. So it answers three things at a glance (is it on, what is it
/// doing, what was just said) and keeps everything else one tap away.
public struct ContentView: View {
    @Bindable var session: LiveSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("showEnglish") private var showEnglish = true
    @State private var managingModels = false
    @State private var dark = false
    #if os(iOS)
    @State private var output = PhoneOutput.current
    #endif

    public init(session: LiveSession) { self.session = session }

    public var body: some View {
        VStack(spacing: 0) {
            topBar
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            controls
        }
        .background(InterfaceStyle.canvas)
        .sheet(isPresented: $managingModels) { ModelManager(session: session) }
        #if os(iOS)
        .fullScreenCover(isPresented: $dark) { DarkScreen(session: session) }
        .onChange(of: session.isLive, initial: true) { _, live in
            // Interpreting is foreground-only: an auto-lock would end it.
            UIApplication.shared.isIdleTimerDisabled = live
            if !live { dark = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
            .receive(on: DispatchQueue.main)) { _ in output = PhoneOutput.current }
        #endif
    }

    // MARK: top bar

    private var topBar: some View {
        HStack(spacing: 4) {
            LanguageMenu(languages: $session.languages, names: session.availableLanguages,
                         locked: session.isLive || session.isBusy)
                .layoutPriority(-1)
            Spacer(minLength: 8)
            #if os(macOS)
            AudioMenu(session: session)
            #endif
            #if os(iOS)
            if session.isLive {
                iconButton("moon", label: "Darken the screen") { dark = true }
            }
            #endif
            if !session.isLive { transcriptMenu }
            iconButton("gearshape", label: "Settings") { managingModels = true }
        }
        .padding(.leading, 16).padding(.trailing, 6).padding(.vertical, 4)
    }

    private func iconButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.title3)
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(Color.accentColor)
        .help(label).accessibilityLabel(label)
    }

    private var transcriptMenu: some View {
        Menu {
            Toggle("Show English lines", isOn: $showEnglish)
            Divider()
            Button("Clear conversation", systemImage: "trash", role: .destructive) { session.clear() }
                .disabled(session.lines.isEmpty)
        } label: {
            Image(systemName: "ellipsis.circle").font(.title3)
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .iconMenu().fixedSize()
        .help("Conversation options").accessibilityLabel("Conversation options")
    }

    // MARK: conversation

    @ViewBuilder private var content: some View {
        switch session.phase {
        case .choosingModel:
            ScrollView { ModelPicker(session: session).padding(16).frame(maxWidth: 680) }
                .frame(maxWidth: .infinity)
        case .idle:
            message(session.isBusy ? "Getting ready" : "Starting…") { ProgressView() }
        case .loading(let what):
            message(what) { ProgressView() }
        case .failed(let why):
            message("Interpreter needs attention", detail: why, symbol: "exclamationmark.triangle") {
                Button("Try again") { Task { await session.prepare() } }
                    .buttonStyle(.borderedProminent).disabled(session.isBusy)
            }
        case .ready where visible.isEmpty:
            message(readyTitle, detail: readyDetail, symbol: "headphones") { EmptyView() }
        case .live where visible.isEmpty:
            message("Translations appear here as people speak.") { EmptyView() }
        case .ready, .live:
            transcript
        }
    }

    private func message<Extra: View>(_ title: String, detail: String? = nil, symbol: String? = nil,
                                      @ViewBuilder extra: () -> Extra) -> some View {
        VStack(spacing: 10) {
            if let symbol {
                Image(systemName: symbol).font(.largeTitle).foregroundStyle(.secondary)
                    .padding(.bottom, 4).accessibilityHidden(true)
            }
            Text(title).font(.title3.weight(.medium))
            if let detail { Text(detail).foregroundStyle(.secondary) }
            extra().padding(.top, 6)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: 420)
        .padding(24)
    }

    private var readyTitle: String {
        #if os(iOS)
        output.isHeadphones ? "Ready to interpret" : "Put your headphones in"
        #else
        "Ready to interpret"
        #endif
    }

    private var readyDetail: String {
        let chosen = session.languages.filter { $0 != "en" }
        if chosen.isEmpty { return "Other languages are spoken to you in English." }
        let verb = chosen.count == 1 ? "is" : "are"
        return "\(session.languageList(chosen)) \(verb) spoken to you in English; other languages are skipped."
    }

    private var transcript: some View {
        ScrollViewReader { scroll in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(visible) { line in
                        LineView(line: line, prominent: line.id == latestID, isLive: session.isLive).id(line.id)
                    }
                }
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(16)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: session.lines) {
                guard let last = visible.last else { return }
                if reduceMotion { scroll.scrollTo(last.id, anchor: .bottom) }
                else { withAnimation(.easeOut(duration: 0.2)) { scroll.scrollTo(last.id, anchor: .bottom) } }
            }
        }
    }

    private var visible: [LiveSession.Line] {
        session.lines.filter { showEnglish || ($0.silence != .english && $0.silence != .echo) }
    }

    /// The newest piece meant for the listener stays large, even when English
    /// was said after it: that is the line to catch up on.
    private var latestID: Int? {
        visible.last { $0.silence == nil || $0.silence == .unclear }?.id
    }

    // MARK: controls

    private var controls: some View {
        VStack(spacing: 12) {
            if session.isLive {
                Label {
                    Text(session.hearing.isEmpty ? "Waiting for speech" : session.hearing)
                        .lineLimit(2)
                        .foregroundStyle(session.hearing.isEmpty ? .tertiary : .secondary)
                } icon: {
                    Image(systemName: "ear").foregroundStyle(.secondary)
                }
                .font(.callout)
                .frame(maxWidth: 720, alignment: .leading)
                .accessibilityLabel(session.hearing.isEmpty ? "Waiting for speech" : "Hearing: \(session.hearing)")
            }
            if let notice = session.notice {
                Label {
                    Text(notice)
                } icon: {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 720, alignment: .leading)
            }
            LiveButton(session: session)
            Text(status)
                .font(.footnote).monospacedDigit().foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
        }
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 10)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .top) { Divider() }
    }

    /// One status for the whole screen: where the English goes before Live,
    /// what the interpreter is doing during it.
    private var status: String {
        switch session.phase {
        case .live:
            if session.speaking {
                if let lag = session.lines.last(where: { $0.lag != nil })?.lag {
                    return String(format: "Speaking · %.1f s behind", lag)
                }
                return "Speaking"
            }
            return session.translating ? "Translating…" : "Listening"
        case .ready:
            // The microphone permission prompt can hold the start up.
            if session.isBusy { return "Starting…" }
            return ([outputName] + [session.translationModel?.name].compactMap { $0 }).joined(separator: " · ")
        case .failed:
            return "Stopped"
        case .loading, .idle, .choosingModel:
            return " "
        }
    }

    private var outputName: String {
        #if os(iOS)
        output.name
        #else
        session.speaker ?? "Default output"
        #endif
    }
}

/// Start and stop: one large target, with the microphone level as a ring
/// around it so it's clear at a glance that sound is coming in.
struct LiveButton: View {
    let session: LiveSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if os(iOS)
    private let size: CGFloat = 84
    #else
    private let size: CGFloat = 64
    #endif
    private var enabled: Bool { !session.isBusy && (session.phase == .ready || session.isLive) }
    private var level: CGFloat { session.isLive ? CGFloat(min(1, sqrt(Double(session.level)) * 3)) : 0 }

    var body: some View {
        Button {
            Task { session.isLive ? session.stop() : await session.start() }
        } label: {
            ZStack {
                Circle().fill(session.isLive ? Color.red : Color.accentColor)
                Image(systemName: session.isLive ? "stop.fill" : "mic.fill")
                    .font(.system(size: size * 0.32, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
            .background {
                Circle()
                    .stroke(Color.accentColor.opacity(reduceMotion ? 0.15 + 0.6 * level : 0.45), lineWidth: 5)
                    .scaleEffect(reduceMotion ? 1.12 : 1.06 + 0.22 * level)
                    .opacity(session.isLive ? 1 : 0)
                    .animation(.easeOut(duration: 0.12), value: level)
            }
            .opacity(enabled ? 1 : 0.4)
            .contentShape(Circle())
        }
        .buttonStyle(.plain).disabled(!enabled)
        .padding(10)
        .keyboardShortcut(.space, modifiers: [])
        .help("Start or stop interpreting (Space)")
        .accessibilityLabel(session.isLive ? "Stop interpreting" : "Start interpreting")
    }
}

/// One piece of conversation. The newest translation is large, with what was
/// said under it; older lines are plain, English lines quieter still.
struct LineView: View {
    let line: LiveSession.Line
    var prominent = false
    var isLive = true

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            LanguageChip(code: line.language)
            VStack(alignment: .leading, spacing: 4) { content }
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var content: some View {
        switch line.silence {
        case .english?, .echo?:
            Text(line.source).italic().foregroundStyle(.secondary)
        case .language?:
            Text(line.source).foregroundStyle(.tertiary)
            Text("Skipped: not one of your languages").font(.caption).foregroundStyle(.tertiary)
        case .unclear?:
            Label {
                Text(line.translation ?? "Please repeat this piece.")
            } icon: {
                Image(systemName: "questionmark.circle").foregroundStyle(.orange)
            }
            .font(prominent ? .title3.weight(.medium) : .body)
            Text(line.source).font(.callout).foregroundStyle(.secondary)
        case nil:
            if let translation = line.translation {
                Text(translation).font(prominent ? .title2.weight(.semibold) : .body)
                if prominent {
                    Text(line.source).font(.callout).foregroundStyle(.secondary)
                    if line.brief { Text("Shortened to catch up").font(.caption).foregroundStyle(.tertiary) }
                }
            } else {
                Text(line.source).font(prominent ? .title3 : .body).foregroundStyle(.secondary)
                Text(isLive ? "Translating…" : "Stopped before translation").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }
}

/// Who spoke a line: "PL", "HU". Blank when the detector wasn't sure.
struct LanguageChip: View {
    let code: String?
    var body: some View {
        Text(code?.uppercased() ?? "")
            .font(.caption2.weight(.semibold)).monospaced()
            .foregroundStyle(.secondary)
            .frame(width: 28, height: 18)
            .background(code == nil ? Color.clear : InterfaceStyle.surface, in: RoundedRectangle(cornerRadius: 5))
            .accessibilityHidden(code == nil)
            .accessibilityLabel(code.map { Languages.names[$0] ?? $0 } ?? "")
    }
}

struct LanguageMenu: View {
    @Binding var languages: [String]
    let names: [String: String]
    let locked: Bool
    private var all: [(code: String, name: String)] {
        names.map { (code: $0.key, name: $0.value) }.sorted { $0.name < $1.name }
    }
    private var selected: [String] { languages.filter { $0 != "en" } }
    private var any: Bool { selected.isEmpty }
    private var summary: String {
        if any { return "Any language" }
        if selected.count > 2 { return "\(selected.count) languages" }
        return Languages.list(selected, names: names)
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
                ForEach(all.filter { $0.code != "en" }, id: \.code) { language in
                    Toggle(language.name, isOn: binding(language.code))
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "globe")
                Text(summary + " → English").lineLimit(1)
                if !locked { Image(systemName: "chevron.down").font(.caption2.weight(.bold)) }
            }
            .font(.callout.weight(.medium))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(InterfaceStyle.surface, in: Capsule())
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .iconMenu()
        #if os(macOS)
        .fixedSize()
        #endif
        .disabled(locked)
        .help("Choose the languages spoken here. Other languages are skipped.")
        .accessibilityLabel("Spoken languages")
        .accessibilityValue(any ? "Any supported language into English" : Languages.list(selected, names: names) + " into English")
    }
}

#if os(macOS)
/// Which microphone hears the room and where the English goes.
struct AudioMenu: View {
    @Bindable var session: LiveSession
    var body: some View {
        Menu {
            Picker("Microphone", selection: $session.microphone) {
                Text("System default").tag(String?.none)
                ForEach(AudioDevices.all().filter(\.isInput)) { Text($0.name).tag(Optional($0.name)) }
            }
            Picker("Listen through", selection: $session.speaker) {
                Text("System default").tag(String?.none)
                ForEach(AudioDevices.all().filter(\.isOutput)) { Text($0.name).tag(Optional($0.name)) }
            }
        } label: {
            Image(systemName: "headphones").font(.title3)
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .iconMenu().fixedSize()
        .disabled(session.isLive || session.isBusy)
        .help("Microphone and output").accessibilityLabel("Microphone and output")
    }
}
#endif

#if os(iOS)
/// Where the phone sends sound now, by the name people know it by.
struct PhoneOutput: Equatable {
    let name: String
    let isHeadphones: Bool

    static var current: PhoneOutput {
        guard let port = AVAudioSession.sharedInstance().currentRoute.outputs.first else {
            return PhoneOutput(name: "iPhone speaker", isHeadphones: false)
        }
        switch port.portType {
        case .builtInSpeaker, .builtInReceiver:
            return PhoneOutput(name: "iPhone speaker", isHeadphones: false)
        case .headphones, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .usbAudio:
            return PhoneOutput(name: port.portName, isHeadphones: true)
        default:
            return PhoneOutput(name: port.portName, isHeadphones: false)
        }
    }
}

/// While live in a pocket or face up on the table: black, the last line dim,
/// and a way to stop. A tap anywhere else brings the screen back.
struct DarkScreen: View {
    let session: LiveSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let latest = session.lines.last { $0.silence == nil && $0.translation != nil }
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 28) {
                Spacer()
                Text(latest?.translation ?? "Listening")
                    .font(.title2.weight(.medium))
                    .foregroundStyle(Color(white: 0.5))
                    .multilineTextAlignment(.center)
                Spacer()
                Button { session.stop() } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .font(.headline).foregroundStyle(Color(white: 0.6))
                        .padding(.horizontal, 24).padding(.vertical, 12)
                        .overlay(Capsule().stroke(Color(white: 0.25)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop interpreting")
                Text("Tap anywhere to light the screen").font(.caption).foregroundStyle(Color(white: 0.3))
            }
            .padding(32)
        }
        .contentShape(Rectangle())
        .onTapGesture { dismiss() }
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
    }
}
#endif

extension View {
    /// Menus drawn by their own label, on both platforms: the Mac's borderless
    /// style would flatten it to plain grey text.
    func iconMenu() -> some View {
        menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).foregroundStyle(Color.accentColor)
    }
}
