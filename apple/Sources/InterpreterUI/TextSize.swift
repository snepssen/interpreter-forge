import SwiftUI

/// How big the conversation's text is, on top of the system's own text size:
/// for anyone who needs the translation in letters an arm's length away can
/// read. Remembered between launches.
enum TextSize {
    static let key = "textScale"
    static let steps: [Double] = [0.75, 0.9, 1, 1.25, 1.5, 1.75, 2, 2.5, 3, 4]

    static func label(_ scale: Double) -> String { "\(Int((scale * 100).rounded()))%" }

    static func step(_ scale: Double, by delta: Int) -> Double {
        let here = steps.firstIndex { $0 >= scale - 0.001 } ?? steps.count - 1
        return steps[min(max(here + delta, 0), steps.count - 1)]
    }

    /// The point sizes the type scale is built from, as each platform's text
    /// styles have them.
    #if os(macOS)
    static let title: CGFloat = 22, title2: CGFloat = 17, title3: CGFloat = 15
    static let body: CGFloat = 13, callout: CGFloat = 12, caption: CGFloat = 10
    #else
    static let title: CGFloat = 28, title2: CGFloat = 22, title3: CGFloat = 20
    static let body: CGFloat = 17, callout: CGFloat = 16, caption: CGFloat = 12
    #endif
}

/// Tt, then smaller, the size, and larger: in Settings and the iPad's panel.
struct TextSizeControl: View {
    @AppStorage(TextSize.key) private var scale = 1.0

    var body: some View {
        HStack(spacing: 12) {
            Text("Tt")
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Text size")
            Spacer(minLength: 8)
            Button { scale = TextSize.step(scale, by: -1) } label: {
                Image(systemName: "minus").frame(width: 32, height: 32).contentShape(Rectangle())
            }
            .disabled(scale <= TextSize.steps.first!)
            .keyboardShortcut("-", modifiers: .command)
            .accessibilityLabel("Smaller text")
            Text(TextSize.label(scale))
                .monospacedDigit()
                .frame(minWidth: 52)
                .accessibilityHidden(true)
            Button { scale = TextSize.step(scale, by: 1) } label: {
                Image(systemName: "plus").frame(width: 32, height: 32).contentShape(Rectangle())
            }
            .disabled(scale >= TextSize.steps.last!)
            .keyboardShortcut("+", modifiers: .command)
            .accessibilityLabel("Larger text")
        }
        .buttonStyle(.borderless)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Text size")
        .accessibilityValue(TextSize.label(scale))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: scale = TextSize.step(scale, by: 1)
            case .decrement: scale = TextSize.step(scale, by: -1)
            @unknown default: break
            }
        }
    }
}
