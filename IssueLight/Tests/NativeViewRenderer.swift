import AppKit
import SwiftUI

@MainActor
enum NativeViewRenderer {
    static func click<Content: View>(
        _ point: CGPoint,
        in view: Content,
        size: CGSize
    ) {
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
        window.makeKey()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.25))
        hostingView.layoutSubtreeIfNeeded()
        for eventType in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(
                with: eventType,
                location: point,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: eventType == .leftMouseDown ? 1 : 0
            ) {
                window.sendEvent(event)
            }
        }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        window.orderOut(nil)
    }

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
