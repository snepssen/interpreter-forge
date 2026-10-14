import InterpreterCore
import InterpreterEngine
import SwiftUI

/// Everything that isn't the conversation: models, the voice, the transcript.
/// Rows say what each thing is in a few words; the detail is one tap deeper.
public struct SettingsView: View {
    @Bindable var session: LiveSession
    @AppStorage("showEnglish") private var showEnglish = true
    @Environment(\.dismiss) private var dismiss

    public init(session: LiveSession) { self.session = session }

    #if os(iOS)
    private var microphone: Binding<PhoneAudio.Input> {
        Binding(get: { PhoneAudio.Input(session.microphone) },
                set: { session.microphone = $0 == .phone ? nil : $0.rawValue })
    }
    #endif

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(ModelCatalog.all) { model in
                        NavigationLink(value: model) { TranslatorRow(session: session, model: model) }
                    }
                } header: {
                    Text("Translator")
                } footer: {
                    Text("One model is loaded at a time. TranslateGemma translates best; Qwen judges when a thought is complete, so it speaks sooner.")
                }

                Section {
                    ForEach(RecognitionModel.allCases) { model in
                        NavigationLink(value: model) { RecognizerRow(session: session, model: model) }
                    }
                } header: {
                    Text("Speech recognition")
                }

                #if os(iOS)
                Section {
                    Picker("Microphone", selection: microphone) {
                        Text("iPhone").tag(PhoneAudio.Input.phone)
                        Text("Headphones, whole room").tag(PhoneAudio.Input.headphonesRoom)
                        Text("Headphones, your voice").tag(PhoneAudio.Input.headphonesWearer)
                    }
                    .disabled(session.isLive || session.isBusy)
                    if let used = session.inputDescription {
                        LabeledContent("Last used", value: used)
                    }
                } header: {
                    Text("Microphone")
                } footer: {
                    Text("Headphone microphones sit closer to the people talking. AirPods that support it record in full quality; others switch to call quality, and the interpreter then sounds like a phone call. Whole room asks them to hear everyone, not mainly you.")
                }
                #endif

                Section {
                    Picker("Interpret into", selection: $session.target) {
                        ForEach(session.targetChoices, id: \.self) { code in
                            Text(session.isTrained(code) ? session.languageName(code)
                                                         : "\(session.languageName(code)) (untrained)").tag(code)
                        }
                    }
                    .disabled(session.isLive || session.isBusy)
                    Toggle("Untrained languages", isOn: $session.untrainedLanguages)
                        .disabled(session.isLive || session.isBusy)
                } header: {
                    Text("Language")
                } footer: {
                    Text("The voice was trained on \(Languages.list(LiveSession.trainedTargets)). Untrained languages offers Parakeet's other European languages too; the voice reads them without its corrections, so expect an accent and some wrong sounds.")
                }

                Section {
                    Slider(value: $session.voiceVolume, in: 0...1) {
                        Text("Volume")
                    } minimumValueLabel: {
                        Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                    } maximumValueLabel: {
                        Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                    }
                    .disabled(session.captionsOnly)
                    Toggle("Captions only", isOn: $session.captionsOnly)
                } header: {
                    Text("Voice")
                } footer: {
                    Text("Captions only shows translations without speaking them: for a phone on the table when nobody has headphones.")
                }

                Section {
                    Toggle("Show lines already in \(session.languageName(session.target))", isOn: $showEnglish)
                    Button("Clear conversation", role: .destructive) { session.clear() }
                        .disabled(session.lines.isEmpty || session.isLive)
                } header: {
                    Text("Conversation")
                } footer: {
                    Text("Speech, translations and models stay on this device.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .navigationDestination(for: TranslationModel.self) { TranslatorDetail(session: session, model: $0) }
            .navigationDestination(for: RecognitionModel.self) { RecognizerDetail(session: session, model: $0) }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        #if os(macOS)
        // Fit inside the window's minimum height, so Done is never cut off.
        .frame(minWidth: 460, idealWidth: 520, minHeight: 400, idealHeight: 520)
        #else
        .presentationDragIndicator(.visible)
        #endif
    }
}

private struct TranslatorRow: View {
    let session: LiveSession
    let model: TranslationModel

    var body: some View {
        let _ = session.storeChanges
        let downloaded = ModelStore.isDownloaded(model)
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.name)
                Text(model.tagline).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let fraction = session.downloads[model.id] {
                Text("\(Int(fraction * 100))%").monospacedDigit().foregroundStyle(.secondary)
            } else if downloaded && session.translationModel == model {
                Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(Color.accentColor)
                    .accessibilityLabel("In use")
            } else if !downloaded {
                Text(model.fits ? gigabytes(model.download) : "Needs more memory")
                    .font(.callout).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct RecognizerRow: View {
    let session: LiveSession
    let model: RecognitionModel

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.name)
                Text(model.tagline).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if session.recognitionModel == model {
                if session.isBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(Color.accentColor)
                        .accessibilityLabel("In use")
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct TranslatorDetail: View {
    let session: LiveSession
    let model: TranslationModel
    @State private var confirmingDelete = false

    var body: some View {
        let _ = session.storeChanges
        let downloaded = ModelStore.isDownloaded(model)
        let inUse = downloaded && session.translationModel == model
        Form {
            Section { Text(model.summary) }
            Section {
                LabeledContent("Download", value: gigabytes(model.download))
                LabeledContent("Memory while translating", value: String(format: "%.1f GB", model.memoryGB))
                LabeledContent("Judges complete thoughts", value: model.judges ? "Yes" : "No")
            }
            Section {
                if let fraction = session.downloads[model.id] {
                    ProgressView(value: fraction) {
                        Text("Downloading")
                    } currentValueLabel: {
                        Text("\(Int(fraction * 100))% · keep the app open").monospacedDigit()
                    }
                } else if inUse {
                    Label("In use", systemImage: "checkmark.circle")
                } else if downloaded {
                    Button("Use \(model.name)") { Task { await session.use(model) } }
                        .disabled(session.isBusy)
                } else if model.fits {
                    Button("Download \(gigabytes(model.download))") { Task { await session.download(model) } }
                } else {
                    Text("Needs more memory than this device has").foregroundStyle(.secondary)
                }
                if ModelStore.isDeletable(model), session.downloads[model.id] == nil {
                    Button("Delete download", role: .destructive) { confirmingDelete = true }
                        .disabled(session.isLive || session.isBusy)
                }
            } footer: {
                if session.isLive && downloaded && !inUse {
                    Text("Switching stops the conversation while the new model loads.")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(model.name)
        .confirmationDialog("Delete \(model.name)?", isPresented: $confirmingDelete) {
            Button("Delete \(gigabytes(model.download))", role: .destructive) { session.delete(model) }
        } message: {
            Text(inUse ? "It's the model in use; you'll choose another before interpreting." : "You can download it again later.")
        }
    }
}

private struct RecognizerDetail: View {
    let session: LiveSession
    let model: RecognitionModel

    var body: some View {
        let selected = session.recognitionModel == model
        Form {
            Section { Text(model.summary) }
            Section {
                LabeledContent("Languages", value: "\(model.languageNames.count)")
                LabeledContent("Download", value: "about " + gigabytes(model.download))
                if let bytes = ModelStore.recognitionSize(model) {
                    LabeledContent("Stored on this device", value: gigabytes(bytes))
                }
            }
            Section {
                if selected && session.isBusy {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        if case .loading(let status) = session.phase { Text(status) } else { Text("Preparing…") }
                    }
                } else if selected {
                    Label("In use", systemImage: "checkmark.circle")
                } else {
                    Button("Use \(model.name)") { Task { await session.useRecognition(model) } }
                        .disabled(session.isLive || session.isBusy)
                }
            } footer: {
                if model == .whisper {
                    Text("The first setup takes a few minutes. Keep the app open while it prepares.")
                } else if session.isLive && !selected {
                    Text("Stop interpreting to switch.")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(model.name)
    }
}
