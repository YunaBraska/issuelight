import AppKit
import SwiftUI

@MainActor
enum NativeViewRenderer {
    static func exerciseWindow<Content: View>(
        for view: Content,
        size: CGSize
    ) -> Bool {
        let hostingController = NSHostingController(
            rootView: view.frame(width: size.width, height: size.height)
        )
        let hostingView = hostingController.view
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.appearance = NSAppearance(named: .aqua)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hostingController
        window.setContentSize(size)
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.25))
        hostingView.layoutSubtreeIfNeeded()
        if let holdValue = ProcessInfo.processInfo.environment["ISSUELIGHT_UI_HOLD_SECONDS"],
           let holdSeconds = TimeInterval(holdValue),
           holdSeconds > 0 {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: holdSeconds))
        }
        let renderedExpectedSize = hostingView.bounds.size == size
        window.orderOut(nil)
        return renderedExpectedSize
    }

    static func pngData<Content: View>(
        for view: Content,
        size: CGSize
    ) throws -> Data {
        let renderedView = ZStack {
            Color(nsColor: .windowBackgroundColor)
            view
        }
        .frame(width: size.width, height: size.height)
        let hostingController = NSHostingController(rootView: renderedView)
        let hostingView = hostingController.view
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.appearance = NSAppearance(named: .aqua)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hostingController
        window.setContentSize(size)
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        window.makeFirstResponder(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.25))
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            window.orderOut(nil)
            throw NativeViewRendererError.renderFailed
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        window.orderOut(nil)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw NativeViewRendererError.renderFailed
        }
        return data
    }
}

private enum NativeViewRendererError: Error {
    case renderFailed
}
