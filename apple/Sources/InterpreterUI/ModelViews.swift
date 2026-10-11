import InterpreterEngine
import SwiftUI

/// First launch, or whenever no translation model is here: pick one to download.
struct ModelPicker: View {
    let session: LiveSession

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose a translation model").font(.title2.bold())
            Text("It runs on this device, so nothing you hear leaves it. Speech recognition (about 0.5 GB) downloads by itself; pick the translator. You can add, switch or delete models later under the gear.")
                .foregroundStyle(.secondary)
            ForEach(ModelCatalog.all) { model in
                ModelRow(session: session, model: model)
            }
        }
        .frame(maxWidth: 560, alignment: .leading)
    }
}

/// Settings: every model, what it costs, and what to do with it.
public struct ModelManager: View {
    let session: LiveSession
    @Environment(\.dismiss) private var dismiss

    public init(session: LiveSession) { self.session = session }

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(ModelCatalog.all) { model in
                        ModelRow(session: session, model: model)
                    }
                } header: {
                    Text("Translation")
                } footer: {
                    Text("One is in memory at a time. TranslateGemma translates best; a general model also judges when a thought is complete, so pieces cut cleaner.")
                }
                Section {
                    LabeledContent("Parakeet v3, 25 European languages",
                                   value: ModelStore.recognitionSize().map(gigabytes) ?? "downloads when needed")
                } header: {
                    Text("Speech recognition")
                } footer: {
                    Text("Norwegian and other languages outside its 25 come out roughly.")
                }
            }
            .navigationTitle("Models")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .id(session.storeChanges)  // look again when models come or go
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 480)
        #endif
    }
}

struct ModelRow: View {
    let session: LiveSession
    let model: TranslationModel
    @State private var confirmingDelete = false

    var body: some View {
        let downloaded = ModelStore.isDownloaded(model)
        let inUse = session.translationModel == model
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.name).font(.headline)
                if model == ModelCatalog.recommended { Badge("Recommended") }
                if inUse && downloaded { Badge("In use", tint: .green) }
                Spacer()
                Text(gigabytes(model.download)).font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
            Text(model.summary).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !model.fits {
                Label("Needs more memory than this device has", systemImage: "memorychip")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack(spacing: 10) {
                if let fraction = session.downloads[model.id] {
                    ProgressView(value: fraction).frame(maxWidth: 220)
                    Text("\(Int(fraction * 100))%").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                } else if downloaded {
                    if !inUse {
                        Button("Use") { Task { await session.use(model) } }.disabled(session.isLive || session.isBusy)
                    }
                    if ModelStore.isDeletable(model) {
                        Button("Delete", role: .destructive) { confirmingDelete = true }.disabled(session.isLive || session.isBusy)
                    }
                } else {
                    Button("Download") { Task { await session.download(model) } }.disabled(!model.fits)
                }
            }
            .buttonStyle(.bordered).controlSize(.small)
        }
        .padding(.vertical, 6)
        .confirmationDialog("Delete \(model.name)?", isPresented: $confirmingDelete) {
            Button("Delete \(gigabytes(model.download))", role: .destructive) { session.delete(model) }
        } message: {
            Text(inUse ? "It's the model in use; you'll choose another." : "You can download it again later.")
        }
    }
}

struct Badge: View {
    let text: String
    var tint: Color = .accentColor

    init(_ text: String, tint: Color = .accentColor) {
        self.text = text
        self.tint = tint
    }

    var body: some View {
        Text(text).font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2)
            .background(tint.opacity(0.15), in: Capsule()).foregroundStyle(tint)
    }
}

func gigabytes(_ bytes: Int64) -> String { String(format: "%.1f GB", Double(bytes) / 1e9) }
