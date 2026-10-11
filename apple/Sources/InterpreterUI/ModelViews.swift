import InterpreterEngine
import SwiftUI

/// First launch, or after deleting the model in use: one recommended
/// translator to download, the others a tap away.
struct ModelPicker: View {
    let session: LiveSession
    @State private var showOthers = ModelCatalog.all.contains {
        $0 != ModelCatalog.recommended && ModelStore.isDownloaded($0)
    }

    var body: some View {
        let recommended = ModelCatalog.recommended
        let _ = session.storeChanges
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Choose your translator").font(.title2.bold())
                Text("Everything runs on this device. Download a translation model to start; speech recognition follows by itself.")
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(recommended.name).font(.headline)
                    Badge("Recommended")
                }
                Text(recommended.summary).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                PickerAction(session: session, model: recommended)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .panel(tint: .accentColor)
            DisclosureGroup("Other models", isExpanded: $showOthers) {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(ModelCatalog.all.filter { $0 != recommended }) { model in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(model.name).font(.headline)
                                Spacer()
                                Text(gigabytes(model.download)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            }
                            Text(model.summary).font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            PickerAction(session: session, model: model)
                        }
                    }
                }
                .padding(.top, 12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// What can be done with a model from the picker, as a prominent button.
private struct PickerAction: View {
    let session: LiveSession
    let model: TranslationModel

    var body: some View {
        if let fraction = session.downloads[model.id] {
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: fraction).accessibilityLabel("Downloading \(model.name)")
                Text("Downloading · \(Int(fraction * 100))% · keep the app open")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
        } else if ModelStore.isDownloaded(model) {
            Button { Task { await session.use(model) } } label: {
                Label("Use \(model.name)", systemImage: "checkmark.circle").frame(minHeight: 28)
            }
            .buttonStyle(.borderedProminent).disabled(session.isBusy)
        } else if !model.fits {
            Label("Needs more memory than this device has", systemImage: "memorychip")
                .font(.callout).foregroundStyle(.secondary)
        } else {
            Button { Task { await session.download(model) } } label: {
                Label("Download · \(gigabytes(model.download))", systemImage: "arrow.down.circle").frame(minHeight: 28)
            }
            .buttonStyle(.borderedProminent)
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
