# PencilDesk (iPad-to-Mac Drawing Tablet & Display) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn an iPad with Apple Pencil into a low-latency Mac pen display (mirroring + pressure/tilt control), a screenless pen tablet (pure pad mode mapped to the Mac display), and a native iPadOS Scribble handwriting-to-Mac text input bar by extending a fork of `Saffsanity/sill`.

**Architecture:** Fork `Saffsanity/sill` (commit `41e8cb8`) as the streaming, USB-C CDC-NCM / Wi-Fi transport, pairing, and Unicode text-injection backbone. Add wire message kind `45` (`pen`) and `WindowList.pen` capability in `StreamProtocol` to carry coalesced Apple Pencil samples (`phase`, normalized `x`/`y`, `pressure`, `altitude`, `azimuth`, and `target` = streamed source or full display) without the existing 125 Hz pointer throttle. On macOS (`SillHost`), add `PenInjector` using dual-path Quartz `CGEvent` synthesis (mouse event with `mouseSubtypeTabletPoint = 1` + standalone `.tabletPointer`, and `mouseSubtypeTabletProximity = 2` + standalone `.tabletProximity`, capability mask `0x0587`) so Photoshop, Clip Studio Paint, Krita, Affinity, and Blender receive pressure and tilt with zero driver extensions. On iPadOS (`iOSClient`), capture 240 Hz coalesced `UITouch` Pencil samples and hover angles, add a one-tap Pad Mode (stops video decoding and renders an aspect-fitted matte drawing surface mapped to the Mac display), and add a collapsible native Scribble `UITextField` bar that sends recognized handwriting through Sill's existing `InputEvent.text(String)` pipeline.

**Tech Stack:** Swift 6.0 (`swift-tools-version: 6.0`), macOS 14.0+ (`ScreenCaptureKit`, `VideoToolbox`, `CoreGraphics` `CGEvent`, `Network.framework` over USB-C CDC-NCM IPv6 link-local & Wi-Fi), iPadOS 17.0+ (`UIKit` `UITouch` coalescing, `UIHoverGestureRecognizer`, `UIScribbleInteraction` / `UITextField`, `SwiftUI`), zero third-party dependencies.

**Spec:** `/Users/daniel/Documents/iPadMacStylus/docs/streamlined-architecture.md`

## Global Constraints

- **Zero third-party dependencies:** `Package.swift` and `iOSClient/Sill.xcodeproj` must use only system frameworks (`Foundation`, `CoreGraphics`, `AppKit`, `UIKit`, `SwiftUI`, `Network`, `ScreenCaptureKit`, `VideoToolbox`, `AVFoundation`).
- **Additive wire protocol (`SillProtocol.current = 1`):** Never renumber existing `StreamMessageKind` values (`0..28`, `32`, `43`, `44`). Kinds `29..31` and `33..42` are reserved by upstream PRs. Use `case pen = 45`. Put only optional fields on `WindowList` (`public var pen: PenCapability?`) and use `Int` rather than Swift `enum` on the wire for extensible fields (`phase`, `target`, `generation`) so older/newer builds decode without failing.
- **USB transport is CDC-NCM IPv6 link-local (`CableLink.swift`), not `usbmuxd`:** Keep Sill's existing `Network.framework` + Bonjour over the iPad's USB-C NCM network interface untouched.
- **No DriverKit / no `IOHIDUserDevice`:** Tablet pressure and tilt injection on macOS uses user-space `CGEvent` at `.cghidEventTap` (requires only macOS Accessibility permission) and posts both the mouse-subtype form and the standalone `.tabletPointer` / `.tabletProximity` form for universal app compatibility.
- **Xcode 27.0 compatibility (`SILL_HINGE_SDK`):** Guard iOS 27.1 SDK-only symbols (`DeviceHingeContext`, `onHingeChange`, `reservedRegions`, `UITextGrammarCheckingType`) behind `#if SILL_HINGE_SDK` so the iOS target builds cleanly on Xcode 27.0 (`iOS 27.0` SDK) while preserving behavior when compiled with `-DSILL_HINGE_SDK`.
- **Pure logic tested via `Tests/checks/<name>/run.sh`:** Every protocol and coordinate/pressure/state-machine rule lives in a standalone Swift file that compiles with `swiftc -O` and passes its check script before wiring into the host or client.

---

## File Structure & Responsibilities

| File | Action | Responsibility |
| :--- | :--- | :--- |
| `iOSClient/DuoPostureReader.swift` | Modify | Guard iOS 27.1 hinge APIs behind `#if SILL_HINGE_SDK` so Xcode 27.0 compiles `iOSClient` |
| `iOSClient/InputOverlay.swift` | Modify | Guard `grammarCheckingType` behind `#if SILL_HINGE_SDK`; capture coalesced `.pencil` touches & hover angles and emit `PenSample` batches when host advertises `pen` |
| `Sources/StreamProtocol/Pen.swift` | Create | Wire types (`PenPhase`, `PenTarget`, `PenSample`, `PenBatch`, `PenCapability`), clamping/sanitizing (`Pen.accepted`), tilt conversion (`Pen.tilt`), aspect-fit geometry (`Pen.fit`, `Pen.fraction`, `Pen.point`), and per-device state machine (`PenState`) |
| `Sources/StreamProtocol/StreamMessage.swift` | Modify | Add `case pen = 45` to `StreamMessageKind` |
| `Sources/StreamProtocol/Switcher.swift` | Modify | Add optional `public var pen: PenCapability?` to `WindowList` |
| `Tests/checks/pen/run.sh` | Create | Runner script compiling `Sources/StreamProtocol/Pen.swift` + `Tests/checks/pen/main.swift` |
| `Tests/checks/pen/main.swift` | Create | Unit checks for `PenBatch` JSON wire format, `Pen.accepted`, `Pen.tilt`, `Pen.fit`, and `PenState` transitions |
| `Tests/checks/protocol/main.swift` | Modify | Assert `StreamMessageKind(rawValue: 45) == .pen` and `WindowList.pen` round-trip |
| `Sources/SillHost/PenInjector.swift` | Create | Dual-path Quartz `CGEvent` tablet proximity & point synthesis (`mouseSubtypeTabletPoint = 1` + `.tabletPointer`, `mouseSubtypeTabletProximity = 2` + `.tabletProximity`, capabilityMask `0x0587`), integrated with `PointerWatch`, `dryRun`, and `testLog` |
| `Sources/SillHost/InputInjector.swift` | Modify | Expose `let pen = PenInjector()` sharing `watch`, `dryRun`, `testLog`, and release pen states on `releaseKeys(of:)` / `releaseAll()` |
| `Sources/SillHost/LockPolicy.swift` | Modify | Route `.pen` through `Request.input(letsGo:)` so locked/revoked Macs only allow lifting a pressed pen |
| `Sources/SillHost/DisplayWake.swift` | Modify | Treat `.pen` as `.input` user activity so pen strokes wake a sleeping Mac display |
| `Sources/SillHost/StreamCoordinator.swift` | Modify | Advertise `list.pen = PenCapability(...)` in `WindowList`; decode and deliver `.pen` in `handle(_:from:arrived:)` targeting either `currentSourceRect()` (Screen Mode) or `catalog.display?.frame` (Pad Mode, even when `active == .none`) |
| `iOSClient/StreamClient.swift` | Modify | Store `@Published var hostPen: PenCapability?` from `WindowList`, add `@Published var padMode: Bool`, and add `sendPen(_ batch: PenBatch)` on `queue` |
| `iOSClient/PadCanvasView.swift` | Create | Matte dark drawing tablet view for Pad Mode (`StreamSource.none`), aspect-fitting the Mac display's frame via `Pen.fit` and forwarding coalesced Pencil strokes with `PenTarget.display` |
| `iOSClient/ScribbleBar.swift` | Create | Collapsible native iPadOS Scribble handwriting bar (`UITextField` with `UIScribbleInteraction`) that flushes recognized text to `client.sendInput(.text(...))` and supports Return / Backspace |
| `iOSClient/StreamScreen.swift` | Modify | Add toolbar toggles for **Pad** (switches between mirrored Pen Display and screenless Pad Mode) and **Scribble** (shows/hides `ScribbleBar`), and wire `sendPen` into `InputOverlay` |
| `iOSClient/Sill.xcodeproj/project.pbxproj` | Modify | Register `PadCanvasView.swift` and `ScribbleBar.swift` in the `Sill` iOS target |
| `docs/architecture-design.md` | Modify | Fix transport description (USB-C CDC-NCM IPv6 link-local instead of `usbmuxd`) and tablet injection description (`CGEvent` dual-path instead of `IOHIDUserDevice`) |
| `docs/streamlined-architecture.md` | Modify | Fix transport description (`CableLink` CDC-NCM IPv6 link-local instead of `usbmuxd`) |

---

### Task 0: Initialize Repository from Sill & Apply Xcode 27.0 SDK Compatibility Fix

**Files:**
- Modify: `iOSClient/DuoPostureReader.swift:87-149`
- Modify: `iOSClient/InputOverlay.swift:735-745`

**Interfaces:**
- Consumes: Clean clone of `https://github.com/Saffsanity/sill.git` at commit `41e8cb8`, patch `/Users/daniel/Documents/iPadMacStylus/docs/patches/xcode-27.0-hinge-sdk.patch`
- Produces: Git repository in `/Users/daniel/Documents/iPadMacStylus` where both `swift build` (macOS `SillHost`) and `xcodebuild -project iOSClient/Sill.xcodeproj -scheme Sill -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build` succeed on Xcode 27.0.

- [ ] **Step 1: Populate `/Users/daniel/Documents/iPadMacStylus` with the Sill codebase**

Run:
```bash
cp -R /tmp/sill/. /Users/daniel/Documents/iPadMacStylus/
cd /Users/daniel/Documents/iPadMacStylus
git status --short
```
Expected: Only `docs/` appears as untracked (`?? docs/`).

- [ ] **Step 2: Verify the iOS build currently fails on Xcode 27.0 without the SDK guard**

Run:
```bash
cd /Users/daniel/Documents/iPadMacStylus
xcodebuild -project iOSClient/Sill.xcodeproj -scheme Sill -destination 'generic/platform=iOS' -configuration Debug CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "error:|BUILD"
```
Expected: Fails with errors in `DuoPostureReader.swift` (`cannot find type 'DeviceHingeContext' in scope`, `value of type 'Content' has no member 'onHingeChange'`) and `InputOverlay.swift` (`cannot find type 'UITextGrammarCheckingType' in scope`).

- [ ] **Step 3: Apply the verified `SILL_HINGE_SDK` compatibility patch**

Run:
```bash
cd /Users/daniel/Documents/iPadMacStylus
git apply docs/patches/xcode-27.0-hinge-sdk.patch
```

The applied changes in `iOSClient/DuoPostureReader.swift` and `iOSClient/InputOverlay.swift` are:

```swift
// In iOSClient/DuoPostureReader.swift (lines 87-126):
    func body(content: Content) -> some View {
        #if SILL_HINGE_SDK
        if #available(iOS 27.1, *) {
            content
                .environment(\.duoEnvironment, DuoEnvironment(hinge: hinge))
                .onHingeChange { context in
                    let next = DuoPosture.Hinge(context)
                    if next != hinge { hinge = next }
                }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

#if SILL_HINGE_SDK
@available(iOS 27.1, *)
extension DuoPosture.Hinge {
    init(_ context: DeviceHingeContext) {
        switch context.posture {
        case .flat: self = .flat
        case .book: self = .angled
        default: self = .unknown
        }
    }
}
#endif
```

```swift
// In iOSClient/DuoPostureReader.swift (lines 138-151):
        case .reservedRegions:
            #if SILL_HINGE_SDK
            if #available(iOS 27.1, *) {
                let region = geo.reservedRegions(kind: .division, options: .includeInactive).first
                let hinge = hinge(reported: environment.hinge, regionActive: region?.isActive)
                guard hinge != .unknown else { return .unknown }
                return DuoPosture(hinge: hinge, fold: region?.frame)
            }
            #endif
            return .unknown
```

```swift
// In iOSClient/InputOverlay.swift (lines 735-745):
    @available(iOS 18.0, *)
    @objc var mathExpressionCompletionType: UITextMathExpressionCompletionType { get { .no } set {} }
    #if SILL_HINGE_SDK
    @available(iOS 27.0, *)
    @objc var grammarCheckingType: UITextGrammarCheckingType { get { .no } set {} }
    #endif
```

- [ ] **Step 4: Verify both macOS and iOS builds and existing protocol & duo checks pass**

Run:
```bash
cd /Users/daniel/Documents/iPadMacStylus
swift build
xcodebuild -project iOSClient/Sill.xcodeproj -scheme Sill -destination 'generic/platform=iOS' -configuration Debug CODE_SIGNING_ALLOWED=NO build | tail -n 5
Tests/checks/protocol/run.sh
Tests/checks/duo/run.sh
```
Expected: `Build complete!`, `** BUILD SUCCEEDED **`, and both check scripts exit `0` with `0 failed`.

- [ ] **Step 5: Commit baseline**

```bash
cd /Users/daniel/Documents/iPadMacStylus
git add iOSClient/DuoPostureReader.swift iOSClient/InputOverlay.swift docs/patches/xcode-27.0-hinge-sdk.patch
git commit -m "build(ios): guard iOS 27.1 SDK symbols behind SILL_HINGE_SDK for Xcode 27.0

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

### Task 1: Wire Protocol & Pure Pen Math/State (`StreamProtocol/Pen.swift`, Kind 45, `WindowList.pen`)

**Files:**
- Create: `Sources/StreamProtocol/Pen.swift`
- Modify: `Sources/StreamProtocol/StreamMessage.swift:84-95`
- Modify: `Sources/StreamProtocol/Switcher.swift:72-95`
- Create: `Tests/checks/pen/run.sh`
- Create: `Tests/checks/pen/main.swift`
- Modify: `Tests/checks/protocol/main.swift:368-375`

**Interfaces:**
- Consumes: `StreamMessageKind`, `WindowList`, `Wire` in `Sources/StreamProtocol`
- Produces:
  - `StreamMessageKind.pen = 45`
  - `WindowList.pen: PenCapability?`
  - `public enum PenPhase` (`hover = 0`, `down = 1`, `drag = 2`, `up = 3`, `leave = 4`)
  - `public enum PenTarget` (`source = 0`, `display = 1`)
  - `public struct PenSample: Codable, Equatable, Sendable`
  - `public struct PenBatch: Codable, Equatable, Sendable`
  - `public struct PenCapability: Codable, Equatable, Sendable`
  - `public enum Pen` (`generation = 1`, `maxSamples = 64`, `enum Post`, `accepted(_:)`, `tilt(altitude:azimuth:)`, `point(_:in:)`, `fit(_:in:)`, `fraction(_:in:)`)
  - `public struct PenState: Equatable, Sendable` (`near`, `down`, `posts(for:)`, `onlyLifts(_:)`, `letGo()`)

- [ ] **Step 1: Write the failing check script and test suite (`Tests/checks/pen/run.sh` and `Tests/checks/pen/main.swift`)**

Create `Tests/checks/pen/run.sh`:
```bash
#!/bin/bash
# Pen (Sources/StreamProtocol/Pen.swift) on its own: the wire shape of kind 45, what the host
# accepts of a batch, tilt and place mapping, the tablet area's aspect fit, and the pen state machine.
#   Tests/checks/pen/run.sh
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/../common.sh"
swiftc -O Sources/StreamProtocol/Pen.swift "$here/main.swift" -o "$out/check"
"$out/check"
```

Create `Tests/checks/pen/main.swift`:
```swift
// Sources/StreamProtocol/Pen.swift on its own: the wire shape of kind 45, what the host accepts of a
// batch, the tilt and place mapping, the tablet area's fit, and the pen's state machine.
//   swiftc -O Sources/StreamProtocol/Pen.swift Tests/checks/pen/main.swift -o check && ./check
import CoreGraphics
import Foundation

var fails = 0, passes = 0
func check(_ name: String, _ ok: Bool) { if ok { passes += 1; print("ok   \(name)") } else { fails += 1; print("FAIL \(name)") } }
func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }

// MARK: - Wire

let batch = PenBatch(target: PenTarget.display, samples: [
    PenSample(phase: PenPhase.down, x: 0.25, y: 0.75, pressure: 0.5, altitude: 1.0, azimuth: 2.0)])
let data = try! JSONEncoder().encode(batch)
check("a batch round-trips through JSON", (try? JSONDecoder().decode(PenBatch.self, from: data)) == batch)
let json = String(decoding: data, as: UTF8.self)
check("phase and target are plain numbers on the wire", json.contains("\"phase\":1") && json.contains("\"target\":1"))
let cap = PenCapability(generation: Pen.generation, displayWidth: 1512, displayHeight: 982)
check("the capability round-trips", (try? JSONDecoder().decode(PenCapability.self, from: JSONEncoder().encode(cap))) == cap)

// MARK: - What the host accepts

check("an unknown target is refused", Pen.accepted(PenBatch(target: 7, samples: [PenSample(phase: 0, x: 0, y: 0)])) == nil)
check("the source target is accepted", Pen.accepted(PenBatch(target: PenTarget.source, samples: [])) == [])
let messy = PenBatch(target: PenTarget.source, samples: [
    PenSample(phase: 9, x: 0.5, y: 0.5),                                  // unknown phase
    PenSample(phase: PenPhase.drag, x: .nan, y: 0.5, pressure: 0.5),      // not finite
    PenSample(phase: PenPhase.drag, x: 1.5, y: -0.5, pressure: 3, altitude: 4),
    PenSample(phase: PenPhase.hover, x: 0.5, y: 0.5, pressure: 0.8),
    PenSample(phase: PenPhase.up, x: 0.5, y: 0.5, pressure: 0.8),
])
let kept = Pen.accepted(messy)!
check("unknown phases and non-finite samples are dropped", kept.count == 3)
check("places are clamped to 0…1", kept[0].x == 1 && kept[0].y == 0)
check("pressure is clamped to 1 while touching", kept[0].pressure == 1)
check("altitude is clamped to π/2", near(kept[0].altitude, .pi / 2))
check("a hover carries no pressure", kept[1].pressure == 0)
check("an up carries no pressure", kept[2].pressure == 0)
let flood = PenBatch(target: PenTarget.source, samples: Array(repeating: PenSample(phase: PenPhase.drag, x: 0, y: 0), count: 500))
check("at most maxSamples are kept", Pen.accepted(flood)!.count == Pen.maxSamples)

// MARK: - Tilt and place

let upright = Pen.tilt(altitude: .pi / 2, azimuth: 1.3)
check("an upright pen has no tilt", abs(upright.x) < 1e-9 && abs(upright.y) < 1e-9)
let flatRight = Pen.tilt(altitude: 0, azimuth: 0)
check("flat, pointing right: tilt x 1", near(flatRight.x, 1) && abs(flatRight.y) < 1e-9)
let flatDown = Pen.tilt(altitude: 0, azimuth: .pi / 2)
check("flat, pointing down the screen: tilt y 1", abs(flatDown.x) < 1e-9 && near(flatDown.y, 1))
let half = Pen.tilt(altitude: .pi / 3, azimuth: .pi)
check("60° up, pointing left: tilt x −0.5", near(half.x, -0.5))

let rect = CGRect(x: 100, y: 50, width: 1000, height: 500)
check("a sample lands inside the target rectangle",
      Pen.point(PenSample(phase: 0, x: 0.5, y: 0.2), in: rect) == CGPoint(x: 600, y: 150))

// MARK: - The tablet area

let area = Pen.fit(CGSize(width: 16, height: 10), in: CGSize(width: 1000, height: 1000))
check("a 16:10 display in a square: full width, centred", area == CGRect(x: 0, y: 187.5, width: 1000, height: 625))
let tall = Pen.fit(CGSize(width: 10, height: 10), in: CGSize(width: 800, height: 400))
check("a square display in a wide area: full height, centred", tall == CGRect(x: 200, y: 0, width: 400, height: 400))
check("an empty display fills the area", Pen.fit(.zero, in: CGSize(width: 10, height: 20)) == CGRect(x: 0, y: 0, width: 10, height: 20))
let f = Pen.fraction(CGPoint(x: 600, y: 300), in: rect)!
check("a point's fractions in a rectangle", near(f.x, 0.5) && near(f.y, 0.5))
let edge = Pen.fraction(CGPoint(x: -50, y: 9999), in: rect)!
check("a point outside is clamped to the edge", edge.x == 0 && edge.y == 1)
check("an empty rectangle has no fractions", Pen.fraction(.zero, in: .zero) == nil)

// MARK: - The pen's state

func run(_ phases: [Int]) -> [[Pen.Post]] {
    var s = PenState()
    return phases.map { s.posts(for: $0) }
}
check("a whole stroke: enter, move, down, drag, drag, up, move, leave",
      run([PenPhase.hover, PenPhase.down, PenPhase.drag, PenPhase.drag, PenPhase.up, PenPhase.hover, PenPhase.leave])
        == [[.enter, .move], [.down], [.drag], [.drag], [.up], [.move], [.leave]])
check("a down without a hover enters first (an iPad without hover)", run([PenPhase.down]) == [[.enter, .down]])
check("a drag without a down is the down", run([PenPhase.drag, PenPhase.drag]) == [[.enter, .down], [.drag]])
check("a second down while down is a drag", run([PenPhase.down, PenPhase.down]) == [[.enter, .down], [.drag]])
check("a hover while down lifts first", run([PenPhase.down, PenPhase.hover]) == [[.enter, .down], [.up, .move]])
check("a leave while down lifts and leaves", run([PenPhase.down, PenPhase.leave]) == [[.enter, .down], [.up, .leave]])
check("an up when not down posts nothing", run([PenPhase.up]) == [[]])
check("a leave when not near posts nothing", run([PenPhase.leave]) == [[]])
check("an unknown phase posts nothing", run([42]) == [[]])

var held = PenState()
_ = held.posts(for: PenPhase.down)
check("an up only lifts a pen that is down", held.onlyLifts([PenSample(phase: PenPhase.up, x: 0, y: 0)]))
check("an up and a leave only lift", held.onlyLifts([PenSample(phase: PenPhase.up, x: 0, y: 0), PenSample(phase: PenPhase.leave, x: 0, y: 0)]))
check("a drag is more than a lift", !held.onlyLifts([PenSample(phase: PenPhase.up, x: 0, y: 0), PenSample(phase: PenPhase.drag, x: 0, y: 0)]))
check("an empty batch lifts nothing", !held.onlyLifts([]))
check("nothing lifts a pen that is up", !PenState().onlyLifts([PenSample(phase: PenPhase.up, x: 0, y: 0)]))
check("letting go of a down pen: up, then leave", held.letGo() == [.up, .leave] && !held.near && !held.down)
var idle = PenState()
check("letting go of a pen that was never near posts nothing", idle.letGo() == [])

print("\(passes) passed, \(fails) failed")
exit(fails == 0 ? 0 : 1)
```

Make `Tests/checks/pen/run.sh` executable:
```bash
chmod +x /Users/daniel/Documents/iPadMacStylus/Tests/checks/pen/run.sh
```

- [ ] **Step 2: Run the check to verify it fails before implementation**

Run:
```bash
cd /Users/daniel/Documents/iPadMacStylus && Tests/checks/pen/run.sh
```
Expected: Fails with `<unknown>:0: error: no such file or directory: 'Sources/StreamProtocol/Pen.swift'`.

- [ ] **Step 3: Implement `Sources/StreamProtocol/Pen.swift`, `StreamMessageKind.pen = 45`, and `WindowList.pen`**

Create `Sources/StreamProtocol/Pen.swift`:
```swift
import CoreGraphics
import Foundation

/// The Apple Pencil as a pen tablet (kind 45, StreamMessage.swift): batches of samples, each with the
/// Pencil's place, pressure and tilt, which the Mac posts as tablet events (PenInjector). Only to a host
/// whose window list carries `pen` (PenCapability); older hosts map kind 45 to `.unknown` and skip it.
/// Phases and targets are Ints on the wire, never enums, so a later value decodes everywhere and is
/// dropped by `Pen.accepted`.
public enum PenPhase {
    /// Above the glass, not touching (a hover-capable iPad): the pen is near, no button.
    public static let hover = 0
    /// The tip touched: the left button goes down with pressure.
    public static let down = 1
    /// The tip moves on the glass: a drag with pressure.
    public static let drag = 2
    /// The tip lifted: the left button goes up; the pen may still be near.
    public static let up = 3
    /// The pen went out of range: up if still down, then out of proximity.
    public static let leave = 4
}

/// What a batch's fractions are fractions of.
public enum PenTarget {
    /// The streamed picture (the source's rectangle on the Mac): the pen display mode.
    public static let source = 0
    /// The Mac's main display, whether or not anything streams: the pen tablet mode.
    public static let display = 1
}

public struct PenSample: Codable, Equatable, Sendable {
    public var phase: Int
    /// 0…1 across and down the target, top-left origin.
    public var x: Double
    public var y: Double
    /// 0…1; force over the Pencil's maximum force. Zero unless the tip is down.
    public var pressure: Double
    /// Radians, 0 (flat on the glass) to π/2 (upright), UITouch.altitudeAngle.
    public var altitude: Double
    /// Radians in the device view's coordinates (x right, y down), UITouch.azimuthAngle(in:).
    public var azimuth: Double

    public init(phase: Int, x: Double, y: Double, pressure: Double = 0,
                altitude: Double = .pi / 2, azimuth: Double = 0) {
        self.phase = phase; self.x = x; self.y = y; self.pressure = pressure
        self.altitude = altitude; self.azimuth = azimuth
    }
}

public struct PenBatch: Codable, Equatable, Sendable {
    public var target: Int
    public var samples: [PenSample]
    public init(target: Int, samples: [PenSample]) { self.target = target; self.samples = samples }
}

/// `WindowList.pen`: this host takes kind 45. Generation 1 is `PenSample` as above; the display's
/// size (points) lets the device shape its tablet area to the Mac's aspect.
public struct PenCapability: Codable, Equatable, Sendable {
    public var generation: Int
    public var displayWidth: Double
    public var displayHeight: Double
    public init(generation: Int, displayWidth: Double, displayHeight: Double) {
        self.generation = generation; self.displayWidth = displayWidth; self.displayHeight = displayHeight
    }
}

public enum Pen {
    public static let generation = 1
    /// The most samples one batch may carry; the rest are dropped. A batch is one touch callback's
    /// coalesced touches, two to four at 240 Hz.
    public static let maxSamples = 64

    /// One event the Mac posts.
    public enum Post: Equatable, Sendable { case enter, leave, move, down, drag, up }

    /// The samples the host acts on: nil for a target this build does not know; at most `maxSamples`,
    /// unknown phases and non-finite numbers dropped, places, pressure and altitude clamped, pressure
    /// zero unless the tip is down.
    public static func accepted(_ batch: PenBatch) -> [PenSample]? {
        guard batch.target == PenTarget.source || batch.target == PenTarget.display else { return nil }
        return batch.samples.prefix(maxSamples).compactMap(clean)
    }

    static func clean(_ s: PenSample) -> PenSample? {
        guard (PenPhase.hover...PenPhase.leave).contains(s.phase),
              s.x.isFinite, s.y.isFinite, s.pressure.isFinite, s.altitude.isFinite, s.azimuth.isFinite
        else { return nil }
        var c = s
        c.x = clamp(s.x, 0, 1)
        c.y = clamp(s.y, 0, 1)
        let touching = s.phase == PenPhase.down || s.phase == PenPhase.drag
        c.pressure = touching ? clamp(s.pressure, 0, 1) : 0
        c.altitude = clamp(s.altitude, 0, .pi / 2)
        return c
    }

    /// macOS tablet tilt (−1…1 each way, 0 upright) from the Pencil's altitude and azimuth.
    public static func tilt(altitude: Double, azimuth: Double) -> (x: Double, y: Double) {
        let lean = cos(altitude)
        return (clamp(lean * cos(azimuth), -1, 1), clamp(lean * sin(azimuth), -1, 1))
    }

    /// A sample's place in `rect` (the Mac's global points, top-left origin).
    public static func point(_ s: PenSample, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + s.x * rect.width, y: rect.minY + s.y * rect.height)
    }

    /// The largest rectangle of `content`'s aspect centred in `container` (the tablet area on the
    /// device); the whole container when either size is empty.
    public static func fit(_ content: CGSize, in container: CGSize) -> CGRect {
        guard content.width > 0, content.height > 0, container.width > 0, container.height > 0 else {
            return CGRect(origin: .zero, size: container)
        }
        let scale = min(container.width / content.width, container.height / content.height)
        let size = CGSize(width: content.width * scale, height: content.height * scale)
        return CGRect(x: (container.width - size.width) / 2, y: (container.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    /// `p`'s fractions across and down `rect`, clamped to its edges; nil for an empty rectangle.
    public static func fraction(_ p: CGPoint, in rect: CGRect) -> (x: Double, y: Double)? {
        guard rect.width > 0, rect.height > 0 else { return nil }
        return (clamp(Double((p.x - rect.minX) / rect.width), 0, 1),
                clamp(Double((p.y - rect.minY) / rect.height), 0, 1))
    }

    static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(max(v, lo), hi) }
}

/// One device's pen on the Mac: near (in proximity) and down (the left button). Turns each sample's
/// phase into the events that keep the Mac consistent whatever the device missed: a down without a
/// hover enters proximity first, a drag without a down is the down, a hover while down lifts first,
/// a leave lifts and leaves.
public struct PenState: Equatable, Sendable {
    public private(set) var near = false
    public private(set) var down = false
    public init() {}

    public mutating func posts(for phase: Int) -> [Pen.Post] {
        var out: [Pen.Post] = []
        switch phase {
        case PenPhase.hover:
            if down { out.append(.up); down = false }
            if !near { out.append(.enter); near = true }
            out.append(.move)
        case PenPhase.down, PenPhase.drag:
            if !near { out.append(.enter); near = true }
            out.append(down ? .drag : .down)
            down = true
        case PenPhase.up:
            if down { out.append(.up); down = false }
        case PenPhase.leave:
            if down { out.append(.up); down = false }
            if near { out.append(.leave); near = false }
        default:
            break
        }
        return out
    }

    /// The batch only lets go of what this pen holds: it is down and every sample is an up or a leave.
    /// What a locked or revoked device may still send (LockPolicy's `letsGo`).
    public func onlyLifts(_ samples: [PenSample]) -> Bool {
        down && !samples.isEmpty && samples.allSatisfy { $0.phase == PenPhase.up || $0.phase == PenPhase.leave }
    }

    /// What lets go of everything: up if down, leave if near (the device left, or nothing to land on).
    public mutating func letGo() -> [Pen.Post] { posts(for: PenPhase.leave) }
}
```

Modify `Sources/StreamProtocol/StreamMessage.swift` (add `case pen = 45` right before `case unknown = 255`):
```swift
    case keyframeRequest = 44
    // The Apple Pencil as a pen tablet (Pen.swift), after keyframeRequest's 44. Older hosts map it
    // to `.unknown` and skip it; a device sends it only when the host's window list carries `pen`.
    case pen = 45            // device → host: JSON PenBatch — coalesced Pencil samples with pressure and tilt
    case unknown = 255       // never sent: what parseHeader yields for a kind this build does not know
```

Modify `Sources/StreamProtocol/Switcher.swift` (add `public var pen: PenCapability?` right after `public var offConsole: Bool?`):
```swift
    public var offConsole: Bool?
    /// Whether this host takes pen tablet batches (kind 45, Pen.swift), and the main display's point
    /// size for the device's tablet mode. Nil from every host before pen support. Set after the
    /// initializer, as `keyRepeat`.
    public var pen: PenCapability?
```

Modify `Tests/checks/protocol/main.swift` (around line 369, add kind 45 check):
```swift
check("kind 28 is gesture (trackpad gestures), 29 unknown (#66's, skipped), 43 audio (the Mac's sound), 44 the keyframe request, 45 pen",
      header(28)?.kind == .gesture && header(29)?.kind == .unknown && header(43)?.kind == .audio && header(44)?.kind == .keyframeRequest && header(45)?.kind == .pen)
```

- [ ] **Step 4: Run `Tests/checks/pen/run.sh` and `Tests/checks/protocol/run.sh`**

Run:
```bash
cd /Users/daniel/Documents/iPadMacStylus
Tests/checks/pen/run.sh
Tests/checks/protocol/run.sh
```
Expected: `39 passed, 0 failed` in `pen/run.sh`, and `ALL PASS` in `protocol/run.sh`.

- [ ] **Step 5: Commit `StreamProtocol` pen support**

```bash
cd /Users/daniel/Documents/iPadMacStylus
git add Sources/StreamProtocol/Pen.swift Sources/StreamProtocol/StreamMessage.swift Sources/StreamProtocol/Switcher.swift Tests/checks/pen/run.sh Tests/checks/pen/main.swift Tests/checks/protocol/main.swift
git commit -m "feat(protocol): add kind 45 PenBatch wire format, PenCapability and PenState

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

### Task 2: Mac-Side Dual-Path Quartz Tablet Injector (`Sources/SillHost/PenInjector.swift`)

**Files:**
- Create: `Sources/SillHost/PenInjector.swift`
- Modify: `Sources/SillHost/InputInjector.swift:40-75, 130-150`
- Modify: `Sources/SillHost/LockPolicy.swift:360-415`
- Modify: `Sources/SillHost/DisplayWake.swift:100-130`
- Modify: `Sources/SillHost/StreamCoordinator.swift:440-446, 580-590, 1120-1240, 1525-1555, 2345-2365, 2855-2872, 3324-3335`

**Interfaces:**
- Consumes: `Pen`, `PenBatch`, `PenSample`, `PenCapability`, `PenState`, `PenTarget`, `PenPhase` from `StreamProtocol`
- Produces:
  - `@MainActor final class PenInjector` in `Sources/SillHost/PenInjector.swift`:
    - `func apply(_ samples: [PenSample], in rect: CGRect, from device: ObjectIdentifier)`
    - `func releasesWhatItHolds(_ batch: PenBatch, from device: ObjectIdentifier) -> Bool`
    - `func release(device: ObjectIdentifier)`
    - `func releaseAll()`
  - `InputInjector.pen: PenInjector` wired to `watch`, `dryRun`, and `testLog`
  - `StreamCoordinator` advertising `list.pen` in `WindowList` and dispatching `.pen` batches in both Screen Mode (`PenTarget.source` → `currentSourceRect()`) and Pad Mode (`PenTarget.display` → `catalog.display?.frame`, even when `active == .none`).

- [ ] **Step 1: Create `Sources/SillHost/PenInjector.swift`**

Create `Sources/SillHost/PenInjector.swift`:
```swift
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
```

- [ ] **Step 2: Wire `PenInjector` into `InputInjector`, `DisplayWake`, and `StreamCoordinator`**

Modify `Sources/SillHost/InputInjector.swift`:
1. Add `let pen = PenInjector()` right below `private var right = ButtonState()` (around line 45).
2. In `var watch: PointerWatch?`, `var dryRun = false`, and `var testLog = false`, forward to `pen`:
```swift
    let pen = PenInjector()

    var watch: PointerWatch? {
        didSet { pen.watch = watch }
    }
    var dryRun = false {
        didSet { pen.dryRun = dryRun }
    }
    var testLog = false {
        didSet { pen.testLog = testLog }
    }
```
3. In `releaseKeys(of:revoked:)` and `releaseAll()` in `Sources/SillHost/InputInjector.swift`, also release any held pen state (`pen.release(device: device)` in `releaseKeys`, and `pen.releaseAll()` in `releaseAll()`).

Modify `Sources/SillHost/DisplayWake.swift` (in `activity(_:at:)`, around line 117):
```swift
            case .windowCommand: return .windowButton
            case .pressMenuItem: return .menuItem
            case .gesture, .pen: return .input
            default: return nil
```

Modify `Sources/SillHost/StreamCoordinator.swift`:
1. In `handle(_:from:arrived:)` (around line 1120):
   - Decode pen batches once alongside `input`:
     ```swift
     let input = message.kind == .input ? Wire.decode(InputEvent.self, from: message.payload) : nil
     let penBatch = message.kind == .pen ? Wire.decode(PenBatch.self, from: message.payload) : nil
     ```
   - Under `if revoked.contains(sender)`:
     ```swift
     if let penBatch, injector.pen.releasesWhatItHolds(penBatch, from: sender),
        let samples = Pen.accepted(penBatch) {
         injector.pen.apply(samples, in: .null, from: sender)
     }
     ```
   - Under `case .letGo:` of `switch lockDecision(...)`:
     ```swift
     case .letGo:
         if let input { deliver(input, in: .null, from: sender) }
         if let penBatch, let samples = Pen.accepted(penBatch) {
             injector.pen.apply(samples, in: .null, from: sender)
         }
         return
     ```
   - Add `case .pen:` to `switch message.kind` (right after `case .input:`):
     ```swift
     case .pen:
         guard let penBatch, let samples = Pen.accepted(penBatch), !samples.isEmpty else { return }
         let device = ObjectIdentifier(connection)
         let targetRect: CGRect?
         if penBatch.target == PenTarget.display {
             targetRect = (synthetic && pointer.hasTestPointer) ? Self.testPatternRect : catalog.display?.frame
         } else {
             targetRect = currentSourceRect()
         }
         guard let rect = targetRect else {
             if injector.pen.releasesWhatItHolds(penBatch, from: device) {
                 injector.pen.apply(samples, in: .null, from: device)
             }
             return
         }
         if penBatch.target == PenTarget.source,
            samples.contains(where: { $0.phase == PenPhase.down }) {
             gestureChords.input(.click)
             if !synthetic { raiseIfInteracting(.pointer(.leftDown, x: samples[0].x, y: samples[0].y)) }
         }
         injector.pen.apply(samples, in: rect, from: device)
     ```
2. In `lockDecision(_:input:from:reading:)` (around line 1532):
   ```swift
        case .pen:
            guard let batch = Wire.decode(PenBatch.self, from: message.payload),
                  Pen.accepted(batch) != nil else { return .take }
            request = .input(letsGo: injector.pen.releasesWhatItHolds(batch, from: id))
   ```
3. In `windowListMessage(...)` (around line 3329, right after `list.keyRepeat = KeyRepeat.generation`):
   ```swift
        let displaySize = catalog.display?.frame.size ?? CGSize(width: 1920, height: 1080)
        list.pen = PenCapability(generation: Pen.generation,
                                 displayWidth: Double(displaySize.width),
                                 displayHeight: Double(displaySize.height))
   ```

- [ ] **Step 3: Build `SillHost` and run host checks**

Run:
```bash
cd /Users/daniel/Documents/iPadMacStylus
swift build
Tests/checks/lock-policy/run.sh
Tests/checks/display-wake/run.sh
```
Expected: `Build complete!` with zero errors, and both `lock-policy` and `display-wake` checks exit `0`.

- [ ] **Step 4: Commit Mac-side tablet injection**

```bash
cd /Users/daniel/Documents/iPadMacStylus
git add Sources/SillHost/PenInjector.swift Sources/SillHost/InputInjector.swift Sources/SillHost/DisplayWake.swift Sources/SillHost/StreamCoordinator.swift
git commit -m "feat(host): add dual-path CGEvent PenInjector and kind 45 coordinator routing

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

### Task 3: iPad 240 Hz Coalesced Apple Pencil Capture in Screen Mode (`StreamClient` & `InputOverlay`)

**Files:**
- Modify: `iOSClient/StreamClient.swift:886-895, 3550-3558, 3840-3865, 4190-4200`
- Modify: `iOSClient/InputOverlay.swift:635-720, 1538-1595`
- Modify: `iOSClient/StreamScreen.swift:1215-1230`

**Interfaces:**
- Consumes: `Pen`, `PenBatch`, `PenSample`, `PenPhase`, `PenTarget`, `PenCapability`, `Wire`, `StreamMessageKind.pen` from `StreamProtocol`
- Produces:
  - `StreamClient.hostPen: PenCapability?` (published from `WindowList.pen`, cleared on disconnect)
  - `StreamClient.sendPen(_ batch: PenBatch)` (flushes pending pointer moves, encodes `PenBatch` as JSON on `queue`, and sends `.pen` without the 125 Hz `moveInterval` throttle)
  - `InputOverlay` / `InputOverlayView` `sendPen: ((PenBatch) -> Void)?` callback: when `client.hostPen != nil`, `.pencil` touches read `event?.coalescedTouches(for: touch) ?? [touch]` with normalized pressure (`touch.force / touch.maximumPossibleForce`), `altitudeAngle`, and `azimuthAngle(in: self)`, and hover gesture `.began`/`.changed`/`.ended` emits `.hover` / `.leave` samples. Falls back to existing `sendPointer` when connected to an older host (`hostPen == nil`) or for `.indirectPointer` (Magic Keyboard trackpad).

- [ ] **Step 1: Add `hostPen` and `sendPen(_:)` to `iOSClient/StreamClient.swift`**

Modify `iOSClient/StreamClient.swift`:
1. Around line 890 (right after `@Published var hostGestures: Int?`):
   ```swift
   /// Whether this session's Mac takes kind 45 pen tablet batches (`WindowList.pen`), and the main
   /// display's point size for Pad Mode. Cleared with the session.
   @Published var hostPen: PenCapability?
   ```
2. Around line 3552 (where `hostGestures = nil` is cleared on session reset):
   ```swift
   hostGestures = nil
   hostPen = nil
   ```
3. Around line 4194 (where `list.gestures` is applied on receiving `WindowList`):
   ```swift
   if self.hostGestures != list.gestures { self.hostGestures = list.gestures }
   if self.hostPen != list.pen { self.hostPen = list.pen }
   ```
4. Around line 3858 (right after `func sendGesture(...)`):
   ```swift
   /// Sends a batch of coalesced Apple Pencil samples (kind 45) without the pointer's 8 ms move
   /// throttle, flushing any queued pointer move first so cursor order never inverts.
   func sendPen(_ batch: PenBatch) {
       guard hostPen != nil, !batch.samples.isEmpty else { return }
       lastInputAt = ProcessInfo.processInfo.systemUptime
       if batch.samples.contains(where: { $0.phase == PenPhase.down }) {
           onCaretMayMove?()
       }
       let payload = Wire.encode(batch)
       queue.async { [weak self] in
           guard let self else { return }
           self.flushPendingMove()
           self.send(.pen, payload)
       }
   }
   ```

- [ ] **Step 2: Capture coalesced `.pencil` touches and hover angles in `iOSClient/InputOverlay.swift`**

Modify `iOSClient/InputOverlay.swift`:
1. Add `var sendPen: ((PenBatch) -> Void)? = nil` to `InputOverlayView` (around line 24, right below `var send: (InputEvent) -> Void = { _ in }`) and to `struct InputOverlay: UIViewRepresentable` (around line 1545), and wire `uiView.sendPen = sendPen` inside `updateUIView`.
2. Add helper methods in `InputOverlayView` (under `// MARK: - Pencil`, around line 660):
   ```swift
   private func penSample(phase: Int, for touch: UITouch, clamped: Bool) -> PenSample? {
       let point = touch.location(in: self)
       guard let p = normalized(point, clamped: clamped) else { return nil }
       let maxForce = touch.maximumPossibleForce
       let pressure: Double
       if phase == PenPhase.down || phase == PenPhase.drag {
           pressure = maxForce > 0 ? min(max(Double(touch.force / maxForce), 0), 1) : 0.5
       } else {
           pressure = 0
       }
       return PenSample(phase: phase,
                        x: p.x,
                        y: p.y,
                        pressure: pressure,
                        altitude: Double(touch.altitudeAngle),
                        azimuth: Double(touch.azimuthAngle(in: self)))
   }
   ```
3. Update `handleHover(_:)` in `InputOverlayView` (lines 641–652) so when `hoverIsPencil` and `sendPen != nil`, hover emits `PenPhase.hover` on `.began`/`.changed` and `PenPhase.leave` on `.ended`/`.cancelled`:
   ```swift
   @objc private func handleHover(_ gesture: UIHoverGestureRecognizer) {
       switch gesture.state {
       case .began, .changed:
           if gesture.state == .began { hoverIsPencil = false }
           if gesture.zOffset > 0 || gesture.altitudeAngle > 0 { hoverIsPencil = true }
           let loc = gesture.location(in: self)
           if hoverIsPencil, let sendPen, let p = normalized(loc, clamped: true) {
               let sample = PenSample(phase: PenPhase.hover,
                                      x: p.x,
                                      y: p.y,
                                      pressure: 0,
                                      altitude: Double(gesture.altitudeAngle),
                                      azimuth: Double(gesture.azimuthAngle(in: self)))
               sendPen(PenBatch(target: PenTarget.source, samples: [sample]))
               setOwnPointer(CGPoint(x: p.x, y: p.y), .pencil)
               return
           }
           let at = sendPointer(.move, at: loc, clamped: true)
           if hoverIsPencil { setOwnPointer(at, .pencil) } else { setOwnPointer(nil, .none) }
       default:
           if hoverIsPencil, let sendPen {
               let loc = gesture.location(in: self)
               let p = normalized(loc, clamped: true) ?? (x: 0.5, y: 0.5)
               sendPen(PenBatch(target: PenTarget.source,
                                samples: [PenSample(phase: PenPhase.leave, x: p.x, y: p.y)]))
               setOwnPointer(nil, .none)
           }
           hoverIsPencil = false
       }
   }
   ```
4. Update `touchesBegan`, `touchesMoved`, `touchesEnded`, and `touchesCancelled` in `InputOverlayView` (lines 673–712) to send coalesced `PenSample` batches when `touch.type == .pencil` and `sendPen != nil`:
   ```swift
   override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
       momentum.stop()
       guard let touch = Self.pointerTouch(in: touches) else {
           super.touchesBegan(touches, with: event); return
       }
       if touch.type == .pencil, let sendPen {
           let coalesced = event?.coalescedTouches(for: touch) ?? [touch]
           var samples: [PenSample] = []
           for (idx, t) in coalesced.enumerated() {
               let phase = idx == 0 ? PenPhase.down : PenPhase.drag
               if let s = penSample(phase: phase, for: t, clamped: idx > 0) {
                   samples.append(s)
               }
           }
           guard let last = samples.last else { return }
           forgetTyped()
           sendPen(PenBatch(target: PenTarget.source, samples: samples))
           setOwnPointer(CGPoint(x: last.x, y: last.y), .pencil)
           return
       }
       let point = touch.location(in: self)
       guard let at = sendPointer(.move, at: point, clamped: false) else { return }
       ownPointer(at, for: touch)
       forgetTyped()
       pointerButtonIsSecondary = touch.type == .indirectPointer && (event?.buttonMask.contains(.secondary) ?? false)
       sendPointer(pointerButtonIsSecondary ? .rightDown : .leftDown, at: point, clamped: false)
   }

   override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
       guard let touch = Self.pointerTouch(in: touches) else {
           super.touchesMoved(touches, with: event); return
       }
       if touch.type == .pencil, let sendPen {
           let coalesced = event?.coalescedTouches(for: touch) ?? [touch]
           let samples = coalesced.compactMap { penSample(phase: PenPhase.drag, for: $0, clamped: true) }
           guard let last = samples.last else { return }
           sendPen(PenBatch(target: PenTarget.source, samples: samples))
           setOwnPointer(CGPoint(x: last.x, y: last.y), .pencil)
           return
       }
       if let at = sendPointer(.move, at: touch.location(in: self), clamped: true) { ownPointer(at, for: touch) }
   }

   override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
       guard let touch = Self.pointerTouch(in: touches) else {
           super.touchesEnded(touches, with: event); return
       }
       if touch.type == .pencil, let sendPen {
           let coalesced = event?.coalescedTouches(for: touch) ?? []
           var samples = coalesced.dropLast().compactMap { penSample(phase: PenPhase.drag, for: $0, clamped: true) }
           if let up = penSample(phase: PenPhase.up, for: touch, clamped: true) {
               samples.append(up)
           }
           if let last = samples.last {
               sendPen(PenBatch(target: PenTarget.source, samples: samples))
               setOwnPointer(CGPoint(x: last.x, y: last.y), .pencil)
           }
           return
       }
       if let at = sendPointer(pointerButtonIsSecondary ? .rightUp : .leftUp, at: touch.location(in: self), clamped: true) { ownPointer(at, for: touch) }
       pointerButtonIsSecondary = false
   }

   override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
       guard let touch = Self.pointerTouch(in: touches) else {
           super.touchesCancelled(touches, with: event); return
       }
       if touch.type == .pencil, let sendPen {
           let p = normalized(touch.location(in: self), clamped: true) ?? (x: 0.5, y: 0.5)
           sendPen(PenBatch(target: PenTarget.source,
                            samples: [PenSample(phase: PenPhase.leave, x: p.x, y: p.y)]))
           setOwnPointer(nil, .none)
           return
       }
       if let at = sendPointer(pointerButtonIsSecondary ? .rightUp : .leftUp, at: touch.location(in: self), clamped: true) { ownPointer(at, for: touch) }
       pointerButtonIsSecondary = false
   }
   ```

- [ ] **Step 3: Pass `sendPen` from `StreamScreen.swift` into `InputOverlay`**

Modify `iOSClient/StreamScreen.swift` (around line 1216):
```swift
                InputOverlay(videoSize: client.videoSize,
                             send: { client.sendInput($0) },
                             setOwnPointer: { client.setOwnPointer($0, from: $1) },
                             proxy: overlay,
                             isKeyboardShown: $keyboardShown,
                             latchedModifiers: latched,
                             onModifiersConsumed: { latched = [] },
                             sendGesture: { client.sendGesture($0, fingers: $1) },
                             macRepeatsKeys: { KeyTyping.macRepeats(keyRepeat: client.hostKeyRepeat) },
                             readZoom: { [zoom] in zoom.zoom },
                             writeZoom: { [zoom] in zoom.set($0) },
                             sendPen: client.hostPen != nil ? { client.sendPen($0) } : nil)
```

- [ ] **Step 4: Build the iOS target to verify compilation**

Run:
```bash
cd /Users/daniel/Documents/iPadMacStylus
xcodebuild -project iOSClient/Sill.xcodeproj -scheme Sill -destination 'generic/platform=iOS' -configuration Debug CODE_SIGNING_ALLOWED=NO build | tail -n 5
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit iOS 240 Hz Pencil capture**

```bash
cd /Users/daniel/Documents/iPadMacStylus
git add iOSClient/StreamClient.swift iOSClient/InputOverlay.swift iOSClient/StreamScreen.swift
git commit -m "feat(ios): send coalesced 240 Hz Apple Pencil pressure and tilt batches in Screen Mode

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

### Task 4: Screenless Pad Mode (`PadCanvasView.swift` & Toolbar Toggle)

**Files:**
- Create: `iOSClient/PadCanvasView.swift`
- Modify: `iOSClient/StreamClient.swift:890-905`
- Modify: `iOSClient/StreamScreen.swift:1210-1240, 1480-1500`
- Modify: `iOSClient/Sill.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `Pen.fit(_:in:)`, `Pen.fraction(_:in:)`, `PenBatch`, `PenSample`, `PenPhase`, `PenTarget.display`, `StreamClient.sendPen(_:)`, `StreamClient.select(_:)`
- Produces:
  - `StreamClient.padMode: Bool` and `StreamClient.setPadMode(_ on: Bool)` (stops video capture via `select(.none)` when entering Pad Mode, restores `.desktop` when exiting)
  - `struct PadCanvasView: View` in `iOSClient/PadCanvasView.swift`: renders a low-power matte charcoal tablet surface aspect-fitted to `hostPen`'s `displayWidth × displayHeight` with subtle rule grid and live cursor/pressure indicator, forwarding 240 Hz coalesced Pencil strokes with `PenTarget.display`.

- [ ] **Step 1: Add `padMode` state and `setPadMode(_:)` to `iOSClient/StreamClient.swift`**

Modify `iOSClient/StreamClient.swift` (right after `@Published var hostPen: PenCapability?`):
```swift
    /// Screenless drawing tablet mode: when true, the host stops video capture (`StreamSource.none`)
    /// and the iPad shows `PadCanvasView` mapped 1:1 to the Mac's main display aspect ratio.
    @Published var padMode = false
    private var sourceBeforePadMode: StreamSource = .desktop

    func setPadMode(_ on: Bool) {
        guard padMode != on else { return }
        padMode = on
        if on {
            if active != .none { sourceBeforePadMode = active }
            select(.none)
        } else {
            select(sourceBeforePadMode == .none ? .desktop : sourceBeforePadMode)
        }
    }
```
Also reset `padMode = false` where `hostPen = nil` is reset on disconnect.

- [ ] **Step 2: Create `iOSClient/PadCanvasView.swift`**

Create `iOSClient/PadCanvasView.swift`:
```swift
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
```

- [ ] **Step 3: Wire `PadCanvasView` and the Pad toolbar button into `iOSClient/StreamScreen.swift`**

Modify `iOSClient/StreamScreen.swift`:
1. In the stream `ZStack` (around line 1212), show `PadCanvasView(client: client)` when `client.padMode` is on:
   ```swift
            ZStack {
                if client.padMode {
                    PadCanvasView(client: client)
                } else {
                    // Scaled and moved by the picture's zoom, inside the clip below.
                    ZoomedStreamView(client: client, zoom: zoom)
                    // Same frame as the video, so a touch maps straight onto the streamed frame (through the
                    // zoom, StreamZoom.unzoomedPoint).
                    InputOverlay(videoSize: client.videoSize,
                                 send: { client.sendInput($0) },
                                 setOwnPointer: { client.setOwnPointer($0, from: $1) },
                                 proxy: overlay,
                                 isKeyboardShown: $keyboardShown,
                                 latchedModifiers: latched,
                                 onModifiersConsumed: { latched = [] },
                                 sendGesture: { client.sendGesture($0, fingers: $1) },
                                 macRepeatsKeys: { KeyTyping.macRepeats(keyRepeat: client.hostKeyRepeat) },
                                 readZoom: { [zoom] in zoom.zoom },
                                 writeZoom: { [zoom] in zoom.set($0) },
                                 sendPen: client.hostPen != nil ? { client.sendPen($0) } : nil)
                }
            }
   ```
2. In the top bar (around line 1480, right next to the `Desktop` button), add a `Pad` button:
   ```swift
            button(open: client.padMode, symbol: "rectangle.and.pencil.and.ellipsis", label: "Pad",
                   accessibilityLabel: client.padMode ? "Switch to screen mirroring" : "Switch to screenless drawing pad",
                   action: { client.setPadMode(!client.padMode) })
                .opacity(scaleOpen ? 0 : 1)
                .allowsHitTesting(!scaleOpen)
   ```

---

### Task 5: Native iPadOS Scribble Handwriting Bar (`ScribbleBar.swift` & Xcode Project Registration)

**Files:**
- Create: `iOSClient/ScribbleBar.swift`
- Modify: `iOSClient/StreamScreen.swift:106-112, 1230-1240, 1474-1490`
- Modify: `iOSClient/Sill.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `StreamClient.sendInput(_:)` with `.text(String)` and `.key(hidUsage:down:modifiers:)`
- Produces:
  - `struct ScribbleBar: View` in `iOSClient/ScribbleBar.swift`: floating native `UITextField` with `UIScribbleInteraction` enabled and software keyboard suppressed (`inputView = UIView(frame: .zero)`) so writing with Apple Pencil invokes iPadOS Scribble inline, automatically forwarding committed text to the Mac via `client.sendInput(.text(committed))`, plus quick buttons for **Return** (`\n`), **Space** (`" "`), **Backspace** (HID usage `0x2A`), and **Clear**.

- [ ] **Step 1: Create `iOSClient/ScribbleBar.swift`**

Create `iOSClient/ScribbleBar.swift`:
```swift
import StreamProtocol
import SwiftUI
import UIKit

/// Floating handwriting bar powered by iPadOS's native Apple Pencil Scribble engine.
/// Every committed word or character recognized by Scribble is immediately sent to the Mac
/// via `InputEvent.text(String)`, which `InputInjector.type` injects as Unicode characters.
struct ScribbleBar: View {
    let sendEvent: (InputEvent) -> Void
    let onClose: () -> Void
    @State private var buffer = ""

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "scribble.variable")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.75))

            ScribbleTextField(
                placeholder: "Handwrite here with Apple Pencil (Scribble → Mac)…",
                text: $buffer,
                onCommitChunk: { chunk in
                    guard !chunk.isEmpty else { return }
                    sendEvent(.text(chunk))
                },
                onBackspace: {
                    sendEvent(.key(hidUsage: 0x2A, down: true, modifiers: 0))
                    sendEvent(.key(hidUsage: 0x2A, down: false, modifiers: 0))
                },
                onReturn: {
                    sendEvent(.text("\n"))
                }
            )
            .frame(height: 38)

            Button {
                sendEvent(.text(" "))
            } label: {
                Label("Space", systemImage: "space")
                    .labelStyle(.iconOnly)
                    .frame(width: 34, height: 34)
                    .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)

            Button {
                sendEvent(.key(hidUsage: 0x2A, down: true, modifiers: 0))
                sendEvent(.key(hidUsage: 0x2A, down: false, modifiers: 0))
            } label: {
                Image(systemName: "delete.left")
                    .frame(width: 34, height: 34)
                    .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)

            Button {
                sendEvent(.text("\n"))
            } label: {
                Image(systemName: "return")
                    .frame(width: 34, height: 34)
                    .background(Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 30, height: 30)
                    .background(Color.white.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(red: 0.11, green: 0.12, blue: 0.15).opacity(0.95))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                )
        )
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }
}

private struct ScribbleTextField: UIViewRepresentable {
    let placeholder: String
    @Binding var text: String
    let onCommitChunk: (String) -> Void
    let onBackspace: () -> Void
    let onReturn: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> BackspaceDetectingTextField {
        let tf = BackspaceDetectingTextField()
        tf.delegate = context.coordinator
        tf.onEmptyBackspace = onBackspace
        tf.attributedPlaceholder = NSAttributedString(
            string: placeholder,
            attributes: [.foregroundColor: UIColor.white.withAlphaComponent(0.42)]
        )
        tf.textColor = .white
        tf.font = .systemFont(ofSize: 17, weight: .regular)
        tf.backgroundColor = UIColor.white.withAlphaComponent(0.06)
        tf.layer.cornerRadius = 8
        tf.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 10, height: 1))
        tf.leftViewMode = .always
        tf.autocorrectionType = .no
        tf.autocapitalizationType = .none
        tf.smartQuotesType = .no
        tf.smartDashesType = .no
        // Suppress the full on-screen software keyboard when tapped with Pencil so the canvas stays visible.
        tf.inputView = UIView(frame: .zero)
        tf.inputAssistantItem.leadingBarButtonGroups = []
        tf.inputAssistantItem.trailingBarButtonGroups = []
        tf.addTarget(context.coordinator, action: #selector(Coordinator.editingChanged(_:)), for: .editingChanged)
        return tf
    }

    func updateUIView(_ uiView: BackspaceDetectingTextField, context: Context) {
        context.coordinator.parent = self
        uiView.onEmptyBackspace = onBackspace
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: ScribbleTextField

        init(_ parent: ScribbleTextField) { self.parent = parent }

        @objc func editingChanged(_ sender: UITextField) {
            // Wait until any marked (in-progress) composition finishes before flushing to Mac.
            guard sender.markedTextRange == nil else { return }
            let current = sender.text ?? ""
            guard !current.isEmpty else { return }
            parent.onCommitChunk(current)
            sender.text = ""
            parent.text = ""
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            if let remaining = textField.text, !remaining.isEmpty {
                parent.onCommitChunk(remaining)
                textField.text = ""
                parent.text = ""
            }
            parent.onReturn()
            return false
        }
    }
}

private final class BackspaceDetectingTextField: UITextField {
    var onEmptyBackspace: (() -> Void)?

    override func deleteBackward() {
        let wasEmpty = (text ?? "").isEmpty
        super.deleteBackward()
        if wasEmpty { onEmptyBackspace?() }
    }
}
```

- [ ] **Step 2: Mount `ScribbleBar` and its toolbar button in `iOSClient/StreamScreen.swift`**

Modify `iOSClient/StreamScreen.swift`:
1. Add `@State private var scribbleShown = false` right below `@State private var keyboardShown = false` (around line 106).
2. Add an `.overlay(alignment: .bottom)` on the stream container (around line 1230, right below `.overlay(alignment: .top) { LinkLineView(text: shownLinkLine) }`):
   ```swift
            .overlay(alignment: .bottom) {
                if scribbleShown {
                    ScribbleBar(
                        sendEvent: { client.sendInput($0) },
                        onClose: { scribbleShown = false }
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
   ```
3. In the top bar (around line 1478, right after the `Keyboard` button), add a `Scribble` button:
   ```swift
            button(open: scribbleShown, symbol: "scribble.variable", label: "Scribble",
                   accessibilityLabel: scribbleShown ? "Hide handwriting bar" : "Show handwriting bar",
                   action: { withAnimation(.easeOut(duration: 0.16)) { scribbleShown.toggle() } })
                .opacity(scaleOpen ? 0 : 1)
                .allowsHitTesting(!scaleOpen)
   ```

- [ ] **Step 3: Register `PadCanvasView.swift` and `ScribbleBar.swift` in `iOSClient/Sill.xcodeproj/project.pbxproj`**

Modify `iOSClient/Sill.xcodeproj/project.pbxproj`:
1. Under `/* Begin PBXBuildFile section */`, add:
   ```pbxproj
   		A1000001000000000000A090 /* PadCanvasView.swift in Sources */ = {isa = PBXBuildFile; fileRef = A1000001000000000000F090 /* PadCanvasView.swift */; };
   		A1000001000000000000A091 /* ScribbleBar.swift in Sources */ = {isa = PBXBuildFile; fileRef = A1000001000000000000F091 /* ScribbleBar.swift */; };
   ```
2. Under `/* Begin PBXFileReference section */`, add:
   ```pbxproj
   		A1000001000000000000F090 /* PadCanvasView.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = PadCanvasView.swift; sourceTree = "<group>"; };
   		A1000001000000000000F091 /* ScribbleBar.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ScribbleBar.swift; sourceTree = "<group>"; };
   ```
3. Under the `iOSClient` `PBXGroup` children list (around `A1000001000000000000F009 /* InputOverlay.swift */`), add:
   ```pbxproj
   				A1000001000000000000F090 /* PadCanvasView.swift */,
   				A1000001000000000000F091 /* ScribbleBar.swift */,
   ```
4. Under the `Sill` target `PBXSourcesBuildPhase` files list (around `A1000001000000000000A008 /* InputOverlay.swift in Sources */`), add:
   ```pbxproj
   				A1000001000000000000A090 /* PadCanvasView.swift in Sources */,
   				A1000001000000000000A091 /* ScribbleBar.swift in Sources */,
   ```

- [ ] **Step 4: Build both macOS and iOS targets and run checks**

Run:
```bash
cd /Users/daniel/Documents/iPadMacStylus
swift build
xcodebuild -project iOSClient/Sill.xcodeproj -scheme Sill -destination 'generic/platform=iOS' -configuration Debug CODE_SIGNING_ALLOWED=NO build | tail -n 5
Tests/checks/pen/run.sh
Tests/checks/protocol/run.sh
```
Expected: `Build complete!`, `** BUILD SUCCEEDED **`, and all checks pass with `0 failed`.

- [ ] **Step 5: Commit Pad Mode and Scribble Bar**

```bash
cd /Users/daniel/Documents/iPadMacStylus
git add iOSClient/PadCanvasView.swift iOSClient/ScribbleBar.swift iOSClient/StreamClient.swift iOSClient/StreamScreen.swift iOSClient/Sill.xcodeproj/project.pbxproj
git commit -m "feat(ios): add PadCanvasView screenless tablet mode and native ScribbleBar

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

### Task 6: Architecture Doc Corrections & End-to-End Verification

**Files:**
- Modify: `docs/architecture-design.md`
- Modify: `docs/streamlined-architecture.md`

**Interfaces:**
- Consumes: Completed implementation from Tasks 0–5
- Produces: Accurate architecture documentation reflecting CDC-NCM IPv6 link-local USB transport (`CableLink.swift`) and user-space dual-path `CGEvent` tablet synthesis (`PenInjector.swift`), plus verified end-to-end synthetic host test log for kind 45 pen events and `.text` handwriting injection.

- [ ] **Step 1: Correct transport and injection descriptions in `docs/architecture-design.md` and `docs/streamlined-architecture.md`**

Update `docs/streamlined-architecture.md` and `docs/architecture-design.md` to replace references to `usbmuxd` / `PeerTalk` / `IOHIDUserDevice` with Sill's actual USB-C CDC-NCM virtual network interface (`CableLink.swift` IPv6 link-local + Bonjour) and `PenInjector.swift` dual-path Quartz `CGEvent` injection (`mouseSubtypeTabletPoint = 1` + `.tabletPointer`, `mouseSubtypeTabletProximity = 2` + `.tabletProximity`, wire kind `45`).

- [ ] **Step 2: Run the full check suite across protocol, cable-link, lock-policy, display-wake, and pen**

Run:
```bash
cd /Users/daniel/Documents/iPadMacStylus
Tests/checks/run-all.sh pen protocol cable-link lock-policy display-wake duo
```
Expected: Every check passes (`0 failed`).

- [ ] **Step 3: Commit documentation updates**

```bash
cd /Users/daniel/Documents/iPadMacStylus
git add docs/architecture-design.md docs/streamlined-architecture.md docs/superpowers/plans/2026-11-08-ipad-mac-stylus.md
git commit -m "docs: align architecture docs with CDC-NCM USB transport and kind 45 PenInjector plan

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

## Self-Review Checklist

1. **Spec coverage against the user's 3 core requirements:**
   - **Requirement 1 (System handwriting recognition sent to Mac):** Covered in **Task 5** (`iOSClient/ScribbleBar.swift`), which uses iPadOS's built-in `UITextField` Scribble engine and sends recognized Chinese/English strings via `InputEvent.text(String)` to `InputInjector.type` on macOS.
   - **Requirement 2 (Mirror Mac screen with touch/pencil control):** Covered in **Task 0** (Sill `ScreenCaptureKit` + `VideoToolbox` HEVC + `AVSampleBufferDisplayLayer` pipeline) and **Task 3** (240 Hz coalesced Apple Pencil capture over the mirrored view).
   - **Requirement 3 (Drawing tablet & pen display functions without per-app adapters):**
     - Universal system-level pressure & tilt injection: **Task 1** (`StreamProtocol/Pen.swift`, kind `45`) + **Task 2** (`SillHost/PenInjector.swift` dual-path `CGEvent` posting both `mouseSubtypeTabletPoint = 1` and standalone `.tabletPointer`).
     - Screenless drawing tablet mode (Pad Mode) alongside Pen Display mode (Screen Mode): **Task 4** (`iOSClient/PadCanvasView.swift` + `StreamClient.setPadMode(_:)` + `PenTarget.display` handled in `StreamCoordinator` even when `active == .none`).
2. **Placeholder scan:** No `TBD`, `TODO`, or omitted code blocks remain; every created file and modified section has complete Swift code and exact shell commands.
3. **Type & signature consistency across tasks:**
   - `PenPhase` (`hover`, `down`, `drag`, `up`, `leave`), `PenTarget` (`source`, `display`), `PenSample`, `PenBatch`, `PenCapability`, `Pen` (`generation`, `maxSamples`, `accepted`, `tilt`, `point`, `fit`, `fraction`), and `PenState` (`near`, `down`, `posts(for:)`, `onlyLifts(_:)`, `letGo()`) defined in Task 1 match all call sites in Tasks 2, 3, and 4.
   - `StreamClient.hostPen: PenCapability?`, `StreamClient.sendPen(_ batch: PenBatch)`, and `StreamClient.setPadMode(_ on: Bool)` defined in Tasks 3–4 match `InputOverlay`, `PadCanvasView`, and `StreamScreen`.

