import SwiftUI

struct PointerHoverFeedback: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(.secondary.opacity(isEnabled && isHovering ? 0.14 : 0))
            )
            .onHover { isHovering = isEnabled && $0 }
    }
}

extension View {
    func pointerHoverFeedback(cornerRadius: CGFloat = 5) -> some View {
        modifier(PointerHoverFeedback(cornerRadius: cornerRadius))
    }

    func opaqueInteractiveSurface() -> some View {
        background(Color(nsColor: .windowBackgroundColor))
            .presentationBackground(Color(nsColor: .windowBackgroundColor))
    }
}
