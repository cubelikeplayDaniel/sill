import StreamProtocol
import SwiftUI
import UIKit

/// Screenless drawing tablet surface (Pad Mode). Draws an aspect-fitted matte active region matching
/// the Mac's main display and streams coalesced 240 Hz Apple Pencil samples with `PenTarget.display`.
struct PadCanvasView: View {
    @ObservedObject var client: StreamClient
    @State private var lastPoint: CGPoint?
    @State private var lastPressure: Double = 0

    private var displaySize: CGSize {
        if let pen = client.hostPen, pen.displayWidth > 0, pen.displayHeight > 0 {
            return CGSize(width: pen.displayWidth, height: pen.displayHeight)
        }
        return CGSize(width: 16, height: 10)
    }

    var body: some View {
        GeometryReader { geo in
            let activeRect = Pen.fit(displaySize, in: geo.size)
            ZStack(alignment: .topLeading) {
                Color(red: 0.06, green: 0.06, blue: 0.07)

                // Active tablet surface matched to the Mac display's aspect ratio
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(red: 0.10, green: 0.10, blue: 0.12))
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)

                    // Subtle rule-of-thirds registration crosshair
                    Path { path in
                        for step in [1.0 / 3.0, 2.0 / 3.0] {
                            let x = activeRect.width * step
                            path.move(to: CGPoint(x: x, y: 0))
                            path.addLine(to: CGPoint(x: x, y: activeRect.height))
                            let y = activeRect.height * step
                            path.move(to: CGPoint(x: 0, y: y))
                            path.addLine(to: CGPoint(x: activeRect.width, y: y))
                        }
                    }
                    .stroke(Color.white.opacity(0.05), lineWidth: 1)

                    if let pt = lastPoint {
                        Circle()
                            .strokeBorder(Color.white.opacity(0.65), lineWidth: 1.5)
                            .background(Circle().fill(Color.white.opacity(0.15 + 0.55 * lastPressure)))
                            .frame(width: 10 + 18 * lastPressure, height: 10 + 18 * lastPressure)
                            .position(x: pt.x * activeRect.width, y: pt.y * activeRect.height)
                    }

                    Text("PAD MODE · \(Int(displaySize.width))×\(Int(displaySize.height))")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.32))
                        .padding(12)
                }
                .frame(width: activeRect.width, height: activeRect.height)
                .offset(x: activeRect.minX, y: activeRect.minY)
                .allowsHitTesting(false)

                PadTouchRepresentable(
                    activeRect: activeRect,
                    sendPen: { batch in client.sendPen(batch) },
                    sendFallbackPointer: { event in client.sendInput(event) },
                    usesPenProtocol: client.hostPen != nil,
                    onFeedback: { normPt, pressure in
                        lastPoint = normPt
                        lastPressure = pressure
                    }
                )
            }
        }
    }
}

private struct PadTouchRepresentable: UIViewRepresentable {
    let activeRect: CGRect
    let sendPen: (PenBatch) -> Void
    let sendFallbackPointer: (InputEvent) -> Void
    let usesPenProtocol: Bool
    let onFeedback: (CGPoint?, Double) -> Void

    func makeUIView(context: Context) -> PadTouchUIView {
        let v = PadTouchUIView()
        v.isMultipleTouchEnabled = false
        v.backgroundColor = .clear
        return v
    }

    func updateUIView(_ uiView: PadTouchUIView, context: Context) {
        uiView.activeRect = activeRect
        uiView.sendPen = sendPen
        uiView.sendFallbackPointer = sendFallbackPointer
        uiView.usesPenProtocol = usesPenProtocol
        uiView.onFeedback = onFeedback
    }
}

private final class PadTouchUIView: UIView {
    var activeRect: CGRect = .zero
    var sendPen: (PenBatch) -> Void = { _ in }
    var sendFallbackPointer: (InputEvent) -> Void = { _ in }
    var usesPenProtocol = true
    var onFeedback: (CGPoint?, Double) -> Void = { _, _ in }

    override init(frame: CGRect) {
        super.init(frame: frame)
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
        addGestureRecognizer(hover)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func sample(phase: Int, for touch: UITouch) -> PenSample? {
        guard let f = Pen.fraction(touch.location(in: self), in: activeRect) else { return nil }
        let maxForce = touch.maximumPossibleForce
        let pressure: Double
        if phase == PenPhase.down || phase == PenPhase.drag {
            pressure = maxForce > 0 ? min(max(Double(touch.force / maxForce), 0), 1) : 0.5
        } else {
            pressure = 0
        }
        return PenSample(phase: phase,
                         x: f.x,
                         y: f.y,
                         pressure: pressure,
                         altitude: Double(touch.altitudeAngle),
                         azimuth: Double(touch.azimuthAngle(in: self)))
    }

    @objc private func handleHover(_ gesture: UIHoverGestureRecognizer) {
        guard usesPenProtocol, let f = Pen.fraction(gesture.location(in: self), in: activeRect) else { return }
        switch gesture.state {
        case .began, .changed:
            let s = PenSample(phase: PenPhase.hover,
                              x: f.x,
                              y: f.y,
                              pressure: 0,
                              altitude: Double(gesture.altitudeAngle),
                              azimuth: Double(gesture.azimuthAngle(in: self)))
            sendPen(PenBatch(target: PenTarget.display, samples: [s]))
            onFeedback(CGPoint(x: f.x, y: f.y), 0)
        default:
            let s = PenSample(phase: PenPhase.leave, x: f.x, y: f.y)
            sendPen(PenBatch(target: PenTarget.display, samples: [s]))
            onFeedback(nil, 0)
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        let coalesced = event?.coalescedTouches(for: touch) ?? [touch]
        let samples = coalesced.enumerated().compactMap { idx, t in
            sample(phase: idx == 0 ? PenPhase.down : PenPhase.drag, for: t)
        }
        guard let last = samples.last else { return }
        if usesPenProtocol {
            sendPen(PenBatch(target: PenTarget.display, samples: samples))
        } else {
            sendFallbackPointer(.pointer(.move, x: last.x, y: last.y))
            sendFallbackPointer(.pointer(.leftDown, x: last.x, y: last.y))
        }
        onFeedback(CGPoint(x: last.x, y: last.y), last.pressure)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        let coalesced = event?.coalescedTouches(for: touch) ?? [touch]
        let samples = coalesced.compactMap { sample(phase: PenPhase.drag, for: $0) }
        guard let last = samples.last else { return }
        if usesPenProtocol {
            sendPen(PenBatch(target: PenTarget.display, samples: samples))
        } else {
            sendFallbackPointer(.pointer(.move, x: last.x, y: last.y))
        }
        onFeedback(CGPoint(x: last.x, y: last.y), last.pressure)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        let coalesced = event?.coalescedTouches(for: touch) ?? []
        var samples = coalesced.dropLast().compactMap { sample(phase: PenPhase.drag, for: $0) }
        if let up = sample(phase: PenPhase.up, for: touch) { samples.append(up) }
        if let last = samples.last {
            if usesPenProtocol {
                sendPen(PenBatch(target: PenTarget.display, samples: samples))
            } else {
                sendFallbackPointer(.pointer(.leftUp, x: last.x, y: last.y))
            }
        }
        onFeedback(nil, 0)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first,
              let f = Pen.fraction(touch.location(in: self), in: activeRect) else {
            onFeedback(nil, 0); return
        }
        if usesPenProtocol {
            sendPen(PenBatch(target: PenTarget.display,
                             samples: [PenSample(phase: PenPhase.leave, x: f.x, y: f.y)]))
        } else {
            sendFallbackPointer(.pointer(.leftUp, x: f.x, y: f.y))
        }
        onFeedback(nil, 0)
    }
}
