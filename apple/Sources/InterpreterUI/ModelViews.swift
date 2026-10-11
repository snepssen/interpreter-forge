import InterpreterEngine
import SwiftUI

struct ModelPicker: View {
    let session: LiveSession
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Choose your translator").font(.title2.bold())
                Text("Speech stays on this device. Choose a translation model to get started; speech recognition downloads automatically.")
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 4)
            ForEach(ModelCatalog.all) { model in
                ModelRow(session: session, model: model)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

public struct ModelManager: View {
    let session: LiveSession
    @Environment(\.dismiss) private var dismiss
    public init(session: LiveSession) { self.session = session }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Translation").font(.title3.bold())
                        Text("Choose the balance of quality and speed that works for your conversation. One model is loaded at a time.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(ModelCatalog.all) { model in
                        ModelRow(session: session, model: model)
                    }
                    Text("Speech recognition").font(.title3.bold()).padding(.top, 12)
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Parakeet v3", systemImage: "waveform").font(.headline)
                        Text("25 European languages").font(.callout).foregroundStyle(.secondary)
                        Text(ModelStore.recognitionSize().map { gigabytes($0) + " stored on this device" } ?? "Downloads when needed")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("Languages outside the supported set may be recognised poorly.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .panel()
                }
                .padding(20)
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
            }
            .background(InterfaceStyle.canvas)
            .navigationTitle("Models")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, idealWidth: 620, minHeight: 520, idealHeight: 680)
        #else
        .presentationDragIndicator(.visible)
        #endif
    }
}

struct ModelRow: View {
    let session: LiveSession
    let model: TranslationModel
    @State private var confirmingDelete = false

    var body: some View {
        let downloaded = ModelStore.isDownloaded(model)
        let inUse = session.translationModel == model && downloaded
        VStack(alignment: .leading, spacing: 12) {
            Text(model.name).font(.headline).fixedSize(horizontal: false, vertical: true)
            if model == ModelCatalog.recommended || inUse {
                ViewThatFits(in: .horizontal) {
                    badges(inUse: inUse).fixedSize()
                    VStack(alignment: .leading, spacing: 6) {
                        if model == ModelCatalog.recommended { Badge("Recommended") }
                        if inUse { Badge("In use", tint: .green) }
                    }
                }
            }
            Text(gigabytes(model.download) + " download")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            Text(model.summary).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !model.fits {
                Label {
                    Text("Needs more memory than this device has").foregroundStyle(.primary)
                } icon: {
                    Image(systemName: "memorychip").foregroundStyle(.orange)
                }
                .font(.callout)
            }
            if let fraction = session.downloads[model.id] {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: fraction)
                        .accessibilityLabel("Downloading \(model.name)")
                    Text("Downloading · \(Int(fraction * 100))%")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            } else if downloaded {
                HStack(spacing: 12) {
                    if !inUse {
                        Button { Task { await session.use(model) } } label: {
                            Label("Use model", systemImage: "checkmark.circle").frame(minHeight: 28)
                        }
                        .buttonStyle(.borderedProminent).disabled(session.isLive || session.isBusy)
                    }
                    if ModelStore.isDeletable(model) {
                        Button(role: .destructive) { confirmingDelete = true } label: {
                            Text("Delete").frame(minHeight: 28)
                        }
                        .buttonStyle(.bordered).disabled(session.isLive || session.isBusy)
                    }
                }
            } else {
                Button { Task { await session.download(model) } } label: {
                    Label("Download", systemImage: "arrow.down.circle").frame(minHeight: 28)
                }
                .buttonStyle(.borderedProminent).disabled(!model.fits)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(tint: inUse ? .accentColor : nil)
        .confirmationDialog("Delete \(model.name)?", isPresented: $confirmingDelete) {
            Button("Delete \(gigabytes(model.download))", role: .destructive) { session.delete(model) }
        } message: {
            Text(inUse ? "It's the model in use; you'll choose another." : "You can download it again later.")
        }
    }

    private func badges(inUse: Bool) -> some View {
        HStack(spacing: 8) {
            if model == ModelCatalog.recommended { Badge("Recommended") }
            if inUse { Badge("In use", tint: .green) }
        }
    }
}

struct Badge: View {
    let text: String
    var tint: Color = .accentColor
    init(_ text: String, tint: Color = .accentColor) { self.text = text; self.tint = tint }
    var body: some View {
        Text(text).font(.caption.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(tint.opacity(0.1), in: Capsule()).foregroundStyle(tint)
    }
}

func gigabytes(_ bytes: Int64) -> String { String(format: "%.1f GB", Double(bytes) / 1e9) }
