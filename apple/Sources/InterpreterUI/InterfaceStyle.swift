import SwiftUI

/// Semantic system colors keep the shared UI legible in light and dark mode.
enum InterfaceStyle {
    static var canvas: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .systemGroupedBackground)
        #endif
    }
    static var surface: Color {
        #if os(macOS)
        Color(nsColor: .controlBackgroundColor)
        #else
        Color(uiColor: .secondarySystemGroupedBackground)
        #endif
    }
}

extension View {
    func panel(tint: Color? = nil) -> some View {
        padding(16)
            .background(InterfaceStyle.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder((tint ?? .secondary).opacity(tint == nil ? 0.12 : 0.3), lineWidth: 1)
            }
    }
}
