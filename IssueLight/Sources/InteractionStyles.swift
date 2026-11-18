import SwiftUI

struct PointerHoverFeedback: ViewModifier {
    @State private var isHovering = false
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(.secondary.opacity(isHovering ? 0.14 : 0))
            )
            .onHover { isHovering = $0 }
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
