import CoreGraphics
import Foundation
import StreamProtocol

/// Synthesizes macOS Quartz tablet events for Apple Pencil samples (kind 45, Pen.swift).
///
/// Posts both event forms for each proximity and point transition (derived from CGEvent.h / IOLLEvent.h
/// and verified against AppKit / Clip Studio Paint / Photoshop / Krita):
/// 1. A standard mouse event (`mouseMoved`, `leftMouseDown`, `leftMouseDragged`, `leftMouseUp`) with
///    `.mouseEventSubtype` set to `1` (`kCFNumberTabletPointEventType`) or `2` (`kCFNumberTabletProximityEventType`)
///    and both `.tabletEventPointPressure` and `.mouseEventPressure` populated.
/// 2. A standalone `.tabletPointer` (or `.tabletProximity`) event carrying the same tablet fields for
///    apps that override `NSView.tabletPoint(with:)` or `tabletProximity(with:)` directly.
@MainActor
final class PenInjector {
    private static let subtypeTabletPoint: Int64 = 1
    private static let subtypeTabletProximity: Int64 = 2
    private static let pointerTypePen: Int64 = 1
    private static let capabilityMask: Int64 = 0x0587   // deviceID, pointerX/Y, pressure, tilt, buttons
    private static let vendorID: Int64 = 1
    private static let tabletID: Int64 = 1
    private static let deviceID: Int64 = 1

    private let source = CGEventSource(stateID: .hidSystemState)
    private var states: [ObjectIdentifier: PenState] = [:]
    private var lastPoints: [ObjectIdentifier: CGPoint] = [:]

    var watch: PointerWatch?
    var dryRun = false
    var testLog = false

    /// True when `batch` only lifts or leaves a pen this device currently holds down on the Mac.
    func releasesWhatItHolds(_ batch: PenBatch, from device: ObjectIdentifier) -> Bool {
        guard let state = states[device], let samples = Pen.accepted(batch) else { return false }
        return state.onlyLifts(samples)
    }

    /// Applies validated `samples` inside `rect` (or at the last known point when `rect.isNull`).
    func apply(_ samples: [PenSample], in rect: CGRect, from device: ObjectIdentifier) {
        var state = states[device] ?? PenState()
        for sample in samples {
            let point: CGPoint
            if rect.isNull {
                point = lastPoints[device] ?? .zero
            } else {
                point = Pen.point(sample, in: rect)
                lastPoints[device] = point
            }
            let posts = state.posts(for: sample.phase)
            for post in posts {
                emit(post, sample: sample, at: point)
            }
        }
        if state.near || state.down {
            states[device] = state
        } else {
            states[device] = nil
            lastPoints[device] = nil
        }
    }

    /// Lifts the pen and leaves proximity if `device` disconnected or the source vanished mid-stroke.
    func release(device: ObjectIdentifier) {
        guard var state = states.removeValue(forKey: device) else { return }
        let point = lastPoints.removeValue(forKey: device) ?? .zero
        let neutral = PenSample(phase: PenPhase.leave, x: 0, y: 0)
        for post in state.letGo() {
            emit(post, sample: neutral, at: point)
        }
    }

    /// Lifts and leaves proximity for every connected device (host shutdown).
    func releaseAll() {
        for device in Array(states.keys) {
            release(device: device)
        }
    }

    // MARK: - Event synthesis

    private func emit(_ post: Pen.Post, sample: PenSample, at point: CGPoint) {
        switch post {
        case .enter:
            postProximity(entering: true, at: point)
        case .leave:
            postProximity(entering: false, at: point)
        case .move:
            postPoint(mouseType: .mouseMoved, sample: sample, at: point)
        case .down:
            postPoint(mouseType: .leftMouseDown, sample: sample, at: point)
        case .drag:
            postPoint(mouseType: .leftMouseDragged, sample: sample, at: point)
        case .up:
            postPoint(mouseType: .leftMouseUp, sample: sample, at: point)
        }
    }

    private func postProximity(entering: Bool, at point: CGPoint) {
        guard let mouseEvent = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                                       mouseCursorPosition: point, mouseButton: .left) else { return }
        mouseEvent.setIntegerValueField(.mouseEventSubtype, value: Self.subtypeTabletProximity)
        applyProximityFields(entering: entering, to: mouseEvent)

        guard let standalone = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                                       mouseCursorPosition: point, mouseButton: .left) else { return }
        standalone.type = .tabletProximity
        applyProximityFields(entering: entering, to: standalone)

        if dryRun {
            if testLog {
                print("Test input: pen proximity \(entering ? "enter" : "leave") at \(Int(point.x)),\(Int(point.y))")
            }
            Stats.shared.bump("in.dry")
            return
        }
        mouseEvent.post(tap: .cghidEventTap)
        standalone.post(tap: .cghidEventTap)
        Stats.shared.bump("in.pen")
    }

    private func postPoint(mouseType: CGEventType, sample: PenSample, at point: CGPoint) {
        let tilt = Pen.tilt(altitude: sample.altitude, azimuth: sample.azimuth)
        guard let mouseEvent = CGEvent(mouseEventSource: source, mouseType: mouseType,
                                       mouseCursorPosition: point, mouseButton: .left) else { return }
        // Subtype must be set before tablet fields (CGEvent.h).
        mouseEvent.setIntegerValueField(.mouseEventSubtype, value: Self.subtypeTabletPoint)
        applyPointFields(pressure: sample.pressure, tiltX: tilt.x, tiltY: tilt.y, to: mouseEvent)

        guard let standalone = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                                       mouseCursorPosition: point, mouseButton: .left) else { return }
        standalone.type = .tabletPointer
        applyPointFields(pressure: sample.pressure, tiltX: tilt.x, tiltY: tilt.y, to: standalone)

        watch?.sillMoved(to: point)
        if dryRun {
            if testLog {
                let p = String(format: "%.2f", sample.pressure)
                print("Test input: pen \(mouseType.rawValue) p=\(p) at \(Int(point.x)),\(Int(point.y))")
            }
            Stats.shared.bump("in.dry")
            return
        }
        mouseEvent.post(tap: .cghidEventTap)
        standalone.post(tap: .cghidEventTap)
        Stats.shared.bump("in.pen")
    }

    private func applyProximityFields(entering: Bool, to event: CGEvent) {
        event.setIntegerValueField(.tabletProximityEventEnterProximity, value: entering ? 1 : 0)
        event.setIntegerValueField(.tabletProximityEventPointerType, value: Self.pointerTypePen)
        event.setIntegerValueField(.tabletProximityEventDeviceID, value: Self.deviceID)
        event.setIntegerValueField(.tabletProximityEventCapabilityMask, value: Self.capabilityMask)
        event.setIntegerValueField(.tabletProximityEventVendorID, value: Self.vendorID)
        event.setIntegerValueField(.tabletProximityEventTabletID, value: Self.tabletID)
        event.setIntegerValueField(.tabletProximityEventVendorPointerType, value: Self.pointerTypePen)
        event.setIntegerValueField(.tabletProximityEventPointerID, value: Self.deviceID)
    }

    private func applyPointFields(pressure: Double, tiltX: Double, tiltY: Double, to event: CGEvent) {
        event.setDoubleValueField(.tabletEventPointPressure, value: pressure)
        event.setDoubleValueField(.mouseEventPressure, value: pressure)
        event.setDoubleValueField(.tabletEventTiltX, value: tiltX)
        event.setDoubleValueField(.tabletEventTiltY, value: tiltY)
        event.setIntegerValueField(.tabletEventDeviceID, value: Self.deviceID)
    }
}
