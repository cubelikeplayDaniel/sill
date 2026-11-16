import UIKit
import SwiftUI
import StreamProtocol

/// Description of a key on the virtual keyboard.
struct VirtualKey: Identifiable, Equatable {
    let id: String
    let label: String
    let secondaryLabel: String?
    let hidUsage: UInt16
    let isModifier: Bool
    let modifierFlag: KeyModifiers?
    let widthWeight: CGFloat

    init(id: String? = nil, label: String, secondaryLabel: String? = nil, hidUsage: UInt16,
                isModifier: Bool = false, modifierFlag: KeyModifiers? = nil, widthWeight: CGFloat = 1.0) {
        self.id = id ?? label
        self.label = label
        self.secondaryLabel = secondaryLabel
        self.hidUsage = hidUsage
        self.isModifier = isModifier
        self.modifierFlag = modifierFlag
        self.widthWeight = widthWeight
    }
}

/// Layout definitions for the virtual keyboard.
enum VirtualKeyboardLayout {
    static let row0: [VirtualKey] = [
        VirtualKey(label: "Esc", hidUsage: 0x29, widthWeight: 1.2),
        VirtualKey(label: "1", secondaryLabel: "!", hidUsage: 0x1E),
        VirtualKey(label: "2", secondaryLabel: "@", hidUsage: 0x1F),
        VirtualKey(label: "3", secondaryLabel: "#", hidUsage: 0x20),
        VirtualKey(label: "4", secondaryLabel: "$", hidUsage: 0x21),
        VirtualKey(label: "5", secondaryLabel: "%", hidUsage: 0x22),
        VirtualKey(label: "6", secondaryLabel: "^", hidUsage: 0x23),
        VirtualKey(label: "7", secondaryLabel: "&", hidUsage: 0x24),
        VirtualKey(label: "8", secondaryLabel: "*", hidUsage: 0x25),
        VirtualKey(label: "9", secondaryLabel: "(", hidUsage: 0x26),
        VirtualKey(label: "0", secondaryLabel: ")", hidUsage: 0x27),
        VirtualKey(label: "-", secondaryLabel: "_", hidUsage: 0x2D),
        VirtualKey(label: "=", secondaryLabel: "+", hidUsage: 0x2E),
        VirtualKey(label: "Delete", hidUsage: 0x2A, widthWeight: 1.5),
    ]

    static let row1: [VirtualKey] = [
        VirtualKey(label: "Tab", hidUsage: 0x2B, widthWeight: 1.4),
        VirtualKey(label: "Q", hidUsage: 0x14),
        VirtualKey(label: "W", hidUsage: 0x1A),
        VirtualKey(label: "E", hidUsage: 0x08),
        VirtualKey(label: "R", hidUsage: 0x15),
        VirtualKey(label: "T", hidUsage: 0x17),
        VirtualKey(label: "Y", hidUsage: 0x1C),
        VirtualKey(label: "U", hidUsage: 0x18),
        VirtualKey(label: "I", hidUsage: 0x0C),
        VirtualKey(label: "O", hidUsage: 0x12),
        VirtualKey(label: "P", hidUsage: 0x13),
        VirtualKey(label: "[", secondaryLabel: "{", hidUsage: 0x2F),
        VirtualKey(label: "]", secondaryLabel: "}", hidUsage: 0x30),
        VirtualKey(label: "\\", secondaryLabel: "|", hidUsage: 0x31, widthWeight: 1.1),
    ]

    static let row2: [VirtualKey] = [
        VirtualKey(label: "⌃ Ctrl", hidUsage: 0xE0, isModifier: true, modifierFlag: .control, widthWeight: 1.6),
        VirtualKey(label: "A", hidUsage: 0x04),
        VirtualKey(label: "S", hidUsage: 0x16),
        VirtualKey(label: "D", hidUsage: 0x07),
        VirtualKey(label: "F", hidUsage: 0x09),
        VirtualKey(label: "G", hidUsage: 0x0A),
        VirtualKey(label: "H", hidUsage: 0x0B),
        VirtualKey(label: "J", hidUsage: 0x0D),
        VirtualKey(label: "K", hidUsage: 0x0E),
        VirtualKey(label: "L", hidUsage: 0x0F),
        VirtualKey(label: ";", secondaryLabel: ":", hidUsage: 0x33),
        VirtualKey(label: "'", secondaryLabel: "\"", hidUsage: 0x34),
        VirtualKey(label: "Return", hidUsage: 0x28, widthWeight: 1.8),
    ]

    static let row3: [VirtualKey] = [
        VirtualKey(label: "⇧ Shift", hidUsage: 0xE1, isModifier: true, modifierFlag: .shift, widthWeight: 2.0),
        VirtualKey(label: "Z", hidUsage: 0x1D),
        VirtualKey(label: "X", hidUsage: 0x1B),
        VirtualKey(label: "C", hidUsage: 0x06),
        VirtualKey(label: "V", hidUsage: 0x19),
        VirtualKey(label: "B", hidUsage: 0x05),
        VirtualKey(label: "N", hidUsage: 0x11),
        VirtualKey(label: "M", hidUsage: 0x10),
        VirtualKey(label: ",", secondaryLabel: "<", hidUsage: 0x36),
        VirtualKey(label: ".", secondaryLabel: ">", hidUsage: 0x37),
        VirtualKey(label: "/", secondaryLabel: "?", hidUsage: 0x38),
        VirtualKey(label: "↑", hidUsage: 0x52, widthWeight: 1.1),
        VirtualKey(id: "Shift_R", label: "⇧ Shift", hidUsage: 0xE5, isModifier: true, modifierFlag: .shift, widthWeight: 1.5),
    ]

    static let row4: [VirtualKey] = [
        VirtualKey(label: "⌥ Option", hidUsage: 0xE2, isModifier: true, modifierFlag: .option, widthWeight: 1.6),
        VirtualKey(label: "⌘ Command", hidUsage: 0xE3, isModifier: true, modifierFlag: .command, widthWeight: 1.8),
        VirtualKey(label: "Space", hidUsage: 0x2C, widthWeight: 5.5),
        VirtualKey(label: "←", hidUsage: 0x50, widthWeight: 1.1),
        VirtualKey(label: "↓", hidUsage: 0x51, widthWeight: 1.1),
        VirtualKey(label: "→", hidUsage: 0x4F, widthWeight: 1.1),
    ]

    static let allRows: [[VirtualKey]] = [row0, row1, row2, row3, row4]
}

/// UIKit Multi-touch view that manages simultaneous key presses across multiple touches and sends HID events directly to Mac.
final class MultiTouchKeyboardView: UIView {
    var sendEvent: ((InputEvent) -> Void)?
    var modifierState = VirtualKeyboardModifierState()
    var onClose: (() -> Void)?

    /// Currently active touches mapped to the key they pressed.
    private var activeTouches: [UITouch: (key: VirtualKey, rect: CGRect, downModifiers: KeyModifiers)] = [:]
    /// Modifier keys held down physically by touches.
    private var physicallyHeldModifiers: KeyModifiers = []
    /// Track key bounds for hit testing during layout.
    private var keyRects: [(key: VirtualKey, rect: CGRect)] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setKeyLayout(rects: [(key: VirtualKey, rect: CGRect)]) {
        self.keyRects = rects
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let loc = touch.location(in: self)
            guard let matched = keyRects.first(where: { $0.rect.contains(loc) }) else { continue }
            let key = matched.key

            if key.isModifier, let flag = key.modifierFlag {
                physicallyHeldModifiers.insert(flag)
                // Also send modifier key down
                sendModifierKeysDown(flag)
                activeTouches[touch] = (key: key, rect: matched.rect, downModifiers: physicallyHeldModifiers)
            } else {
                // Regular key pressed!
                let currentMods = effectiveModifiers()
                activeTouches[touch] = (key: key, rect: matched.rect, downModifiers: currentMods)
                // Send key down with modifiers
                sendKeyDown(key.hidUsage, modifiers: currentMods)
            }
        }
        setNeedsDisplay()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let active = activeTouches[touch] else { continue }
            let loc = touch.location(in: self)
            // If touch moved outside its original button frame, release it
            if !active.rect.insetBy(dx: -12, dy: -12).contains(loc) {
                releaseTouch(touch)
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let active = activeTouches[touch] else { continue }
            if active.key.isModifier, let flag = active.key.modifierFlag {
                // Tap/toggle modifier state cycle (Off -> Latched -> Locked -> Off)
                modifierState.cycle(flag)
                physicallyHeldModifiers.remove(flag)
                sendModifierKeysUp(flag)
                activeTouches.removeValue(forKey: touch)
            } else {
                releaseTouch(touch)
                // Regular key finished: consume any latched modifier
                modifierState.consumeLatched()
            }
        }
        setNeedsDisplay()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            releaseTouch(touch)
        }
        setNeedsDisplay()
    }

    private func releaseTouch(_ touch: UITouch) {
        guard let active = activeTouches.removeValue(forKey: touch) else { return }
        if active.key.isModifier, let flag = active.key.modifierFlag {
            physicallyHeldModifiers.remove(flag)
            sendModifierKeysUp(flag)
        } else {
            sendKeyUp(active.key.hidUsage, modifiers: active.downModifiers)
        }
    }

    /// Releases any held keys when view disappears or closes.
    func releaseAll() {
        for (_, active) in activeTouches {
            if active.key.isModifier, let flag = active.key.modifierFlag {
                physicallyHeldModifiers.remove(flag)
                sendModifierKeysUp(flag)
            } else {
                sendKeyUp(active.key.hidUsage, modifiers: active.downModifiers)
            }
        }
        activeTouches.removeAll()
        physicallyHeldModifiers = []
        setNeedsDisplay()
    }

    private func effectiveModifiers() -> KeyModifiers {
        modifierState.activeModifiers.union(physicallyHeldModifiers)
    }

    private func sendKeyDown(_ usage: UInt16, modifiers: KeyModifiers) {
        for event in KeyChord.down(usage, with: modifiers) {
            sendEvent?(event)
        }
    }

    private func sendKeyUp(_ usage: UInt16, modifiers: KeyModifiers) {
        for event in KeyChord.up(usage, with: modifiers) {
            sendEvent?(event)
        }
    }

    private func sendModifierKeysDown(_ flag: KeyModifiers) {
        for event in KeyChord.modifiersDown(flag) {
            sendEvent?(event)
        }
    }

    private func sendModifierKeysUp(_ flag: KeyModifiers) {
        for event in KeyChord.modifiersUp(flag) {
            sendEvent?(event)
        }
    }

    func isKeyPressed(_ key: VirtualKey) -> Bool {
        activeTouches.values.contains { $0.key.id == key.id }
    }
}

/// SwiftUI wrapper around the multi-touch virtual keyboard.
struct BuiltinVirtualKeyboardView: View {
    @ObservedObject var modifierState: VirtualKeyboardModifierState
    let send: (InputEvent) -> Void
    let onClose: () -> Void

    @State private var pressedKeyIDs: Set<String> = []

    init(modifierState: VirtualKeyboardModifierState, send: @escaping (InputEvent) -> Void, onClose: @escaping () -> Void) {
        self.modifierState = modifierState
        self.send = send
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 6) {
            // Header Bar
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "keyboard.fill")
                        .foregroundStyle(Palette.accent)
                    Text("软件内置键盘 (直发 Mac · 支持多键同按)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.text)
                }

                Spacer()

                // Quick modifier indicators
                HStack(spacing: 6) {
                    modifierStatusBadge("⌃", state: modifierState.control) { modifierState.cycle(.control) }
                    modifierStatusBadge("⌥", state: modifierState.option)  { modifierState.cycle(.option) }
                    modifierStatusBadge("⌘", state: modifierState.command) { modifierState.cycle(.command) }
                    modifierStatusBadge("⇧", state: modifierState.shift)   { modifierState.cycle(.shift) }

                    if modifierState.activeModifiers.rawValue != 0 {
                        Button("解锁", action: { modifierState.clearAll() })
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.red.opacity(0.9))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.red.opacity(0.15))
                            .clipShape(Capsule())
                    }
                }

                Button(action: onClose) {
                    Image(systemName: "chevron.down.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(Palette.muted)
                }
                .padding(.leading, 8)
            }
            .padding(.horizontal, 10)
            .padding(.top, 4)

            // Multi-touch Keyboard Surface
            MultiTouchKeyboardRepresentable(modifierState: modifierState, send: send, onClose: onClose)
                .frame(height: 220)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Palette.panel.opacity(0.96))
                .shadow(color: Color.black.opacity(0.35), radius: 10, y: -2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func modifierStatusBadge(_ label: String, state: ModifierKeyState, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 2) {
                Text(label)
                    .font(.system(size: 12, weight: .bold))
                if state == .locked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 8))
                }
            }
            .foregroundStyle(state.isActive ? Color.white : Palette.muted)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(state == .locked ? Palette.accent : (state == .latched ? Palette.accent.opacity(0.6) : Color.white.opacity(0.08)))
            .clipShape(Capsule())
        }
    }
}

/// UIViewRepresentable providing UIKit multi-touch hit testing for the keyboard rows.
struct MultiTouchKeyboardRepresentable: UIViewRepresentable {
    @ObservedObject var modifierState: VirtualKeyboardModifierState
    let send: (InputEvent) -> Void
    let onClose: () -> Void

    func makeUIView(context: Context) -> MultiTouchKeyboardView {
        let view = MultiTouchKeyboardView(frame: .zero)
        view.sendEvent = send
        view.modifierState = modifierState
        view.onClose = onClose
        return view
    }

    func updateUIView(_ uiView: MultiTouchKeyboardView, context: Context) {
        uiView.modifierState = modifierState
        uiView.sendEvent = send
        uiView.onClose = onClose
        context.coordinator.layoutKeys(in: uiView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator {
        func layoutKeys(in view: MultiTouchKeyboardView) {
            // Recompute button layout rects for the view's current bounds
            let bounds = view.bounds
            guard bounds.width > 50 && bounds.height > 50 else { return }

            let rows = VirtualKeyboardLayout.allRows
            let rowCount = CGFloat(rows.count)
            let rowGap: CGFloat = 4
            let keyGap: CGFloat = 4
            let totalRowGaps = rowGap * (rowCount - 1)
            let rowHeight = max(24, (bounds.height - totalRowGaps) / rowCount)

            var keyRects: [(key: VirtualKey, rect: CGRect)] = []

            for (rowIndex, row) in rows.enumerated() {
                let y = CGFloat(rowIndex) * (rowHeight + rowGap)
                let totalWeight = row.reduce(0) { $0 + $1.widthWeight }
                let totalKeyGaps = keyGap * CGFloat(row.count - 1)
                let availableWidth = bounds.width - totalKeyGaps
                let unitWidth = availableWidth / totalWeight

                var currentX: CGFloat = 0
                for key in row {
                    let w = key.widthWeight * unitWidth
                    let rect = CGRect(x: currentX, y: y, width: w, height: rowHeight)
                    keyRects.append((key: key, rect: rect))
                    currentX += w + keyGap
                }
            }
            view.setKeyLayout(rects: keyRects)

            // Add subviews or redraw
            renderKeyboardSubviews(in: view, keyRects: keyRects)
        }

        private func renderKeyboardSubviews(in view: MultiTouchKeyboardView, keyRects: [(key: VirtualKey, rect: CGRect)]) {
            // Remove previous button layers/views if any, then draw crisp key views
            view.subviews.forEach { $0.removeFromSuperview() }

            for item in keyRects {
                let keyView = SingleKeyDisplayView(key: item.key, modifierState: view.modifierState)
                keyView.frame = item.rect
                keyView.isUserInteractionEnabled = false // MultiTouchKeyboardView captures touches
                view.addSubview(keyView)
            }
        }
    }
}

/// Visual display of an individual key button.
private final class SingleKeyDisplayView: UIView {
    private let key: VirtualKey
    private let modifierState: VirtualKeyboardModifierState

    private let titleLabel = UILabel()
    private let secondaryLabel = UILabel()
    private let lockIcon = UIImageView()

    init(key: VirtualKey, modifierState: VirtualKeyboardModifierState) {
        self.key = key
        self.modifierState = modifierState
        super.init(frame: .zero)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        layer.cornerRadius = 6
        layer.masksToBounds = true

        let isMod = key.isModifier
        let modState: ModifierKeyState = {
            if let flag = key.modifierFlag {
                if flag.contains(.control) { return modifierState.control }
                if flag.contains(.option)  { return modifierState.option }
                if flag.contains(.command) { return modifierState.command }
                if flag.contains(.shift)   { return modifierState.shift }
            }
            return .off
        }()

        if modState == .locked {
            backgroundColor = UIColor(named: "AccentColor") ?? UIColor.systemBlue
        } else if modState == .latched {
            backgroundColor = (UIColor(named: "AccentColor") ?? UIColor.systemBlue).withAlphaComponent(0.65)
        } else if isMod {
            backgroundColor = UIColor(white: 0.28, alpha: 0.95)
        } else {
            backgroundColor = UIColor(white: 0.20, alpha: 0.95)
        }

        titleLabel.text = key.label
        titleLabel.font = .systemFont(ofSize: key.label.count > 2 ? 12 : 14, weight: isMod ? .semibold : .medium)
        titleLabel.textColor = modState.isActive ? .white : UIColor(white: 0.92, alpha: 1.0)
        titleLabel.textAlignment = .center
        addSubview(titleLabel)

        if let sec = key.secondaryLabel {
            secondaryLabel.text = sec
            secondaryLabel.font = .systemFont(ofSize: 10, weight: .regular)
            secondaryLabel.textColor = UIColor(white: 0.60, alpha: 1.0)
            secondaryLabel.textAlignment = .center
            addSubview(secondaryLabel)
        }

        if modState == .locked {
            lockIcon.image = UIImage(systemName: "lock.fill")
            lockIcon.tintColor = .white
            addSubview(lockIcon)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if secondaryLabel.text != nil {
            secondaryLabel.frame = CGRect(x: 0, y: 2, width: bounds.width, height: 12)
            titleLabel.frame = CGRect(x: 0, y: 14, width: bounds.width, height: bounds.height - 16)
        } else {
            titleLabel.frame = bounds
        }
        if lockIcon.image != nil {
            lockIcon.frame = CGRect(x: bounds.width - 12, y: 3, width: 9, height: 9)
        }
    }
}
