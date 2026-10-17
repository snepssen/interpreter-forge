import Combine
import InterpreterCore
import InterpreterEngine
import SwiftUI
#if os(iOS)
import AVFoundation
import UIKit
#endif

/// The shared conversation screen. Mostly it isn't looked at: the interpreter
/// is in the headphones. So it answers three things at a glance (is it on, what is it
/// doing, what was just said) and keeps everything else one tap away.
public struct ContentView: View {
    @Bindable var session: LiveSession
    /// The live hearing line grows with the chosen text size, at most double,
    /// so it never crowds the button out.
    @AppStorage(TextSize.key) private var textScale = 1.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("showEnglish") private var showEnglish = true
    @State private var showingSettings = false
    @State private var dark = false
    #if os(iOS)
    @State private var output = PhoneOutput.current
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    public init(session: LiveSession) { self.session = session }

    /// An iPad, or any iOS window as wide: bigger type and a bigger button.
    private var roomy: Bool {
        #if os(iOS)
        sizeClass == .regular
        #else
        false
        #endif
    }

    /// Wide enough for the conversation and a panel beside it: an iPad in
    /// landscape. Portrait (970 points wide with More Space display zoom),
    /// Split View and phones keep the stacked layout.
    private static func wide(_ size: CGSize) -> Bool {
        #if os(iOS)
        size.width >= 900 && size.width > size.height
        #else
        false
        #endif
    }

    public var body: some View {
        GeometryReader { geometry in
            if Self.wide(geometry.size) {
                HStack(spacing: 0) {
                    content.frame(maxWidth: .infinity, maxHeight: .infinity)
                        // No bar above the conversation here: let it fade out under
                        // the status bar rather than scroll beneath the clock.
                        .overlay(alignment: .top) {
                            LinearGradient(colors: [InterfaceStyle.canvas, InterfaceStyle.canvas.opacity(0)],
                                           startPoint: .top, endPoint: .bottom)
                                .frame(height: geometry.safeAreaInsets.top + 28)
                                .ignoresSafeArea(edges: .top)
                                .allowsHitTesting(false)
                        }
                    sidePanel
                        .frame(width: min(400, geometry.size.width * 0.34))
                        .background(InterfaceStyle.surface.opacity(0.45))
                        .overlay(alignment: .leading) { Divider() }
                }
            } else {
                VStack(spacing: 0) {
                    topBar
                    content.frame(maxWidth: .infinity, maxHeight: .infinity)
                    controls
                }
            }
        }
        .background(InterfaceStyle.canvas)
        .sheet(isPresented: $showingSettings) { SettingsView(session: session) }
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
            LanguageMenu(session: session, locked: session.isLive || session.isBusy)
                .layoutPriority(-1)
            Spacer(minLength: 8)
            barButtons
        }
        .padding(.leading, 16).padding(.trailing, 6).padding(.vertical, 4)
    }

    @ViewBuilder private var barButtons: some View {
        #if os(macOS)
        AudioMenu(session: session)
        #endif
        #if os(iOS)
        if session.isLive {
            iconButton("moon", label: "Darken the screen") { dark = true }
        }
        #endif
        iconButton("gearshape", label: "Settings") { showingSettings = true }
    }

    private func iconButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.title3)
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(Color.accentColor)
        .help(label).accessibilityLabel(label)
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
        .frame(maxWidth: roomy ? 520 : 420)
        .padding(24)
    }

    private var readyTitle: String {
        #if os(iOS)
        output.isHeadphones || output.standby != nil ? "Ready to interpret" : "Put your headphones in"
        #else
        "Ready to interpret"
        #endif
    }

    private var readyDetail: String {
        let chosen = session.spoken
        let into = session.languageName(session.target)
        var detail: String
        if chosen.isEmpty {
            detail = "Other languages are spoken to you in \(into)."
        } else {
            let verb = chosen.count == 1 ? "is" : "are"
            detail = "\(session.languageList(chosen)) \(verb) spoken to you in \(into); other languages are skipped."
        }
        #if os(iOS)
        if !output.isHeadphones, let standby = output.standby {
            detail += " \(standby) will switch to this \(ThisDevice.name) when you press Live."
        }
        #endif
        return detail
    }

    private var transcript: some View {
        ScrollViewReader { scroll in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(visible) { line in
                        LineView(line: line, prominent: line.id == latestID, isLive: session.isLive, roomy: roomy)
                            .id(line.id)
                    }
                }
                .frame(maxWidth: roomy ? 860 : 720, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(roomy ? 28 : 16)
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
        session.lines.filter { showEnglish || ($0.silence != .understood && $0.silence != .echo) }
    }

    /// The newest piece meant for the listener stays large, even when their own
    /// language was spoken after it: that is the line to catch up on.
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
                .font(.system(size: TextSize.callout * min(textScale, 2)))
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
            LiveButton(session: session, size: roomy ? 100 : LiveButton.standardSize)
            Text(status)
                .font(roomy ? .callout : .footnote).monospacedDigit().foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
        }
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 10)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .top) { Divider() }
    }

    // MARK: side panel (iPad, landscape)

    /// Everything the stacked layout has above and below the conversation,
    /// beside it instead, with room to spare: the hearing line runs longer,
    /// the button is bigger, and the voice's two quick settings are at hand.
    private var sidePanel: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 4) {
                LanguageMenu(session: session, locked: session.isLive || session.isBusy)
                    .layoutPriority(-1)
                Spacer(minLength: 8)
                barButtons
            }
            Spacer(minLength: 0)
            if session.isLive {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Hearing", systemImage: "ear")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(session.hearing.isEmpty ? "Waiting for speech" : session.hearing)
                        .font(.system(size: TextSize.title3 * min(textScale, 2)))
                        .foregroundStyle(session.hearing.isEmpty ? .tertiary : .primary)
                        .lineLimit(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(16)
                .background(InterfaceStyle.canvas, in: RoundedRectangle(cornerRadius: 14))
                .accessibilityElement(children: .combine)
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
            }
            VStack(spacing: 10) {
                LiveButton(session: session, size: 128)
                Text(status)
                    .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: .infinity)
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 14) {
                TextSizeControl()
                Toggle("Captions only", isOn: $session.captionsOnly)
                HStack(spacing: 12) {
                    Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                    Slider(value: $session.voiceVolume, in: 0...1)
                        .accessibilityLabel("Volume")
                    Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                }
                .disabled(session.captionsOnly)
            }
            .padding(16)
            .background(InterfaceStyle.canvas, in: RoundedRectangle(cornerRadius: 14))
        }
        .padding(.horizontal, 24).padding(.vertical, 16)
    }

    /// One status for the whole screen: where the voice goes before Live,
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
        if !output.isHeadphones, let standby = output.standby { return "\(PhoneOutput.short(standby)), when Live" }
        return output.name
        #else
        session.speaker ?? "Default output"
        #endif
    }
}

/// Start and stop: one large target, with the microphone level as a ring
/// around it so it's clear at a glance that sound is coming in.
struct LiveButton: View {
    let session: LiveSession
    #if os(iOS)
    static let standardSize: CGFloat = 84
    #else
    static let standardSize: CGFloat = 64
    #endif
    var size: CGFloat = LiveButton.standardSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
/// said under it; older lines are plain, lines already in the listener's
/// language quieter still.
struct LineView: View {
    let line: LiveSession.Line
    var prominent = false
    var isLive = true
    /// An iPad's type: one step up, the newest translation two.
    var roomy = false
    @AppStorage(TextSize.key) private var scale = 1.0
    // The system's text size still applies; the chosen scale multiplies it.
    @ScaledMetric(relativeTo: .title) private var title = TextSize.title
    @ScaledMetric(relativeTo: .title2) private var title2 = TextSize.title2
    @ScaledMetric(relativeTo: .title3) private var title3 = TextSize.title3
    @ScaledMetric(relativeTo: .body) private var body_ = TextSize.body
    @ScaledMetric(relativeTo: .callout) private var callout = TextSize.callout
    @ScaledMetric(relativeTo: .caption) private var caption = TextSize.caption

    private func sized(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size * scale, weight: weight)
    }
    private var lead: Font { sized(roomy ? title : title2, .semibold) }
    private var plain: Font { sized(roomy ? title3 : body_) }
    private var under: Font { sized(roomy ? body_ : callout) }
    private var note: Font { sized(caption) }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10 * min(scale, 2)) {
            LanguageChip(code: line.language, scale: scale)
            VStack(alignment: .leading, spacing: 4) { content }
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var content: some View {
        switch line.silence {
        case .understood?, .echo?:
            Text(line.source).font(plain).italic().foregroundStyle(.secondary)
        case .language?:
            Text(line.source).font(plain).foregroundStyle(.tertiary)
            Text("Skipped: not one of your languages").font(note).foregroundStyle(.tertiary)
        case .unclear?:
            Label {
                Text(line.translation ?? "Please repeat this piece.")
            } icon: {
                Image(systemName: "questionmark.circle").foregroundStyle(.orange)
            }
            .font(prominent ? sized(roomy ? title2 : title3, .medium) : plain)
            Text(line.source).font(under).foregroundStyle(.secondary)
        case nil:
            if let translation = line.translation {
                Text(translation).font(prominent ? lead : plain)
                if prominent {
                    Text(line.source).font(under).foregroundStyle(.secondary)
                    if line.brief { Text("Shortened to catch up").font(note).foregroundStyle(.tertiary) }
                }
            } else {
                Text(line.source).font(prominent ? sized(roomy ? title2 : title3) : plain).foregroundStyle(.secondary)
                Text(isLive ? "Translating…" : "Stopped before translation").font(note).foregroundStyle(.tertiary)
            }
        }
    }
}

/// Who spoke a line: "PL", "HU". Blank when the detector wasn't sure.
struct LanguageChip: View {
    let code: String?
    var scale = 1.0
    /// Grows more gently than the text beside it: a label, not the content.
    private var grow: CGFloat { CGFloat(scale.squareRoot()) }
    var body: some View {
        Text(code?.uppercased() ?? "")
            .font(.system(size: 11 * grow, weight: .semibold)).monospaced()
            .foregroundStyle(.secondary)
            .frame(width: 28 * grow, height: 18 * grow)
            .background(code == nil ? Color.clear : InterfaceStyle.surface, in: RoundedRectangle(cornerRadius: 5))
            .accessibilityHidden(code == nil)
            .accessibilityLabel(code.map { Languages.names[$0] ?? $0 } ?? "")
    }
}

/// What is spoken here and what it becomes: "Any language → Hungarian".
struct LanguageMenu: View {
    @Bindable var session: LiveSession
    let locked: Bool
    private var target: String { session.target }
    private var into: String { session.languageName(target) }
    private var all: [(code: String, name: String)] {
        session.availableLanguages.filter { $0.key != target }
            .map { (code: $0.key, name: $0.value) }.sorted { $0.name < $1.name }
    }
    private var selected: [String] { session.spoken }
    private var any: Bool { selected.isEmpty }
    private var summary: String {
        if any { return "Any language" }
        if selected.count > 2 { return "\(selected.count) languages" }
        return session.languageList(selected)
    }
    private func binding(_ code: String) -> Binding<Bool> {
        Binding(get: { session.languages.contains(code) }, set: { on in
            if on && !session.languages.contains(code) { session.languages.append(code) }
            else if !on { session.languages.removeAll { $0 == code } }
        })
    }
    var body: some View {
        Menu {
            Picker(selection: $session.target) {
                ForEach(session.targetChoices, id: \.self) { code in
                    Text(session.isTrained(code) ? session.languageName(code)
                                                 : "\(session.languageName(code)) (untrained)").tag(code)
                }
            } label: {
                Label("Into \(into)", systemImage: "speaker.wave.2")
            }
            .pickerStyle(.menu)
            Divider()
            Button { session.languages = [target] } label: {
                if any { Label("Any language", systemImage: "checkmark") } else { Text("Any language") }
            }
            Section("Only these languages") {
                ForEach(all, id: \.code) { language in
                    Toggle(language.name, isOn: binding(language.code))
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "globe")
                Text(summary + " → " + into).lineLimit(1)
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
        .help("Choose the languages spoken here, and the one they are interpreted into.")
        .accessibilityLabel("Languages")
        .accessibilityValue((any ? "Any supported language" : session.languageList(selected)) + " into " + into)
    }
}

#if os(macOS)
/// Which microphone hears the room and where the voice goes.
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
    /// Headphones connected but playing another device's sound, as AirPods do
    /// with automatic switching: they move here when Live starts.
    var standby: String? = nil

    /// "Tamás’s AirPods Pro 3" → "AirPods Pro 3", for a one-line status.
    static func short(_ name: String) -> String {
        for mark in ["’s ", "'s "] {
            if let range = name.range(of: mark) { return String(name[range.upperBound...]) }
        }
        return name
    }

    static var current: PhoneOutput {
        let session = AVAudioSession.sharedInstance()
        let standby = session.availableInputs?
            .first { $0.portType == .bluetoothHFP || $0.portType == .bluetoothLE }?.portName
        let speaker = PhoneOutput(name: "\(ThisDevice.name) speaker", isHeadphones: false, standby: standby)
        guard let port = session.currentRoute.outputs.first else { return speaker }
        switch port.portType {
        case .builtInSpeaker, .builtInReceiver:
            return speaker
        case .headphones, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .usbAudio:
            return PhoneOutput(name: port.portName, isHeadphones: true)
        default:
            return PhoneOutput(name: port.portName, isHeadphones: false, standby: standby)
        }
    }
}

/// While live in a pocket or face up on the table: black, the last line dim,
/// and a way to stop. A tap anywhere else brings the screen back.
struct DarkScreen: View {
    let session: LiveSession
    @AppStorage(TextSize.key) private var scale = 1.0
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let latest = session.lines.last { $0.silence == nil && $0.translation != nil }
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 28) {
                Spacer()
                Text(latest?.translation ?? "Listening")
                    .font(.system(size: (ThisDevice.isPad ? 34 : 22) * scale, weight: .medium))
                    .minimumScaleFactor(0.3)
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
