import Foundation
import SwiftUI

enum IssueLightResources {
    static let bundle = Bundle(for: IssueLightResourceBundleToken.self)
}

private final class IssueLightResourceBundleToken: NSObject {}

enum IssueLightSignalState: Equatable {
    case critical
    case warning
    case unknown
    case down
    case failed
}

struct IssueLightSignalGlyph: View {
    let state: IssueLightSignalState

    var body: some View {
        ZStack {
            switch state {
            case .critical:
                LighthouseBeamShape()
                    .fill(.primary)
            case .warning:
                LighthouseBeamShape()
                    .stroke(.primary, style: StrokeStyle(lineWidth: 1.35, lineCap: .round, lineJoin: .round))
            case .unknown:
                DottedBeamShape()
                    .fill(.primary)
            case .down, .failed:
                BrokenBeamShape()
                    .fill(.primary)
            }
            LighthouseBodyShape()
                .fill(.primary)
            if state == .down {
                DiagonalCutShape()
                    .stroke(.primary, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

private struct LighthouseBodyShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: point(0.23, 0.91, in: rect))
        path.addLine(to: point(0.34, 0.48, in: rect))
        path.addLine(to: point(0.56, 0.48, in: rect))
        path.addLine(to: point(0.67, 0.91, in: rect))
        path.closeSubpath()
        path.addRoundedRect(
            in: CGRect(
                x: rect.minX + rect.width * 0.31,
                y: rect.minY + rect.height * 0.29,
                width: rect.width * 0.28,
                height: rect.height * 0.17
            ),
            cornerSize: CGSize(width: rect.width * 0.025, height: rect.height * 0.025)
        )
        path.move(to: point(0.27, 0.29, in: rect))
        path.addQuadCurve(
            to: point(0.63, 0.29, in: rect),
            control: point(0.45, 0.08, in: rect)
        )
        path.addLine(to: point(0.57, 0.24, in: rect))
        path.addQuadCurve(
            to: point(0.33, 0.24, in: rect),
            control: point(0.45, 0.13, in: rect)
        )
        path.closeSubpath()
        path.addEllipse(
            in: CGRect(
                x: rect.minX + rect.width * 0.415,
                y: rect.minY + rect.height * 0.08,
                width: rect.width * 0.07,
                height: rect.height * 0.07
            )
        )
        return path
    }
}

private struct LighthouseBeamShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: point(0.57, 0.31, in: rect))
        path.addLine(to: point(0.96, 0.16, in: rect))
        path.addLine(to: point(0.96, 0.55, in: rect))
        path.addLine(to: point(0.57, 0.42, in: rect))
        path.closeSubpath()
        return path
    }
}

private struct BrokenBeamShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: point(0.58, 0.32, in: rect))
        path.addLine(to: point(0.72, 0.27, in: rect))
        path.addLine(to: point(0.72, 0.45, in: rect))
        path.addLine(to: point(0.58, 0.41, in: rect))
        path.closeSubpath()
        path.move(to: point(0.82, 0.23, in: rect))
        path.addLine(to: point(0.96, 0.17, in: rect))
        path.addLine(to: point(0.96, 0.55, in: rect))
        path.addLine(to: point(0.82, 0.50, in: rect))
        path.closeSubpath()
        return path
    }
}

private struct DottedBeamShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let dots: [(CGFloat, CGFloat, CGFloat)] = [
            (0.66, 0.36, 0.08),
            (0.80, 0.31, 0.10),
            (0.94, 0.25, 0.12),
        ]
        for (x, y, diameter) in dots {
            path.addEllipse(
                in: CGRect(
                    x: rect.minX + rect.width * (x - diameter / 2),
                    y: rect.minY + rect.height * (y - diameter / 2),
                    width: rect.width * diameter,
                    height: rect.height * diameter
                )
            )
        }
        return path
    }
}

private struct DiagonalCutShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: point(0.18, 0.19, in: rect))
        path.addLine(to: point(0.75, 0.80, in: rect))
        return path
    }
}

private func point(_ x: CGFloat, _ y: CGFloat, in rect: CGRect) -> CGPoint {
    CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
}
