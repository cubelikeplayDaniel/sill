import StreamProtocol
import SwiftUI
import UIKit

/// Floating handwriting input bar powered by iPadOS native Apple Pencil Scribble (`UIScribbleInteraction`).
/// Handwriting inside the bar's `UITextField` is recognized by the system (Chinese/English/mixed) and
/// forwarded to the Mac via `InputEvent.text` (`StreamMessageKind.input = 5`).
struct ScribbleBar: View {
    @Binding var isShown: Bool
    let sendInput: (InputEvent) -> Void

    @State private var text: String = ""
    @State private var autoSend: Bool = true
    @State private var commitWorkItem: DispatchWorkItem?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "pencil.and.scribble")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.75))

            ScribbleTextField(
                text: $text,
                placeholder: "用 Apple Pencil 在此手写文字（随手写）…",
                onCommit: { flushText(withReturn: false) },
                onEditingChanged: { scheduleAutoFlush() }
            )
            .frame(height: 38)

            Button {
                autoSend.toggle()
            } label: {
                Text(autoSend ? "自动发送" : "手动发送")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(autoSend ? Color.black : Color.white.opacity(0.85))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        Capsule()
                            .fill(autoSend ? Color(red: 0.35, green: 0.78, blue: 0.98) : Color.white.opacity(0.14))
                    )
            }
            .buttonStyle(.plain)

            Button {
                flushText(withReturn: false)
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(text.isEmpty ? Color.white.opacity(0.28) : Color(red: 0.35, green: 0.78, blue: 0.98))
            }
            .buttonStyle(.plain)
            .disabled(text.isEmpty)

            Button {
                flushText(withReturn: true)
            } label: {
                Image(systemName: "return")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.85))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.white.opacity(0.14)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Send Return key to Mac")

            Button {
                sendInput(.key(hidUsage: 0x2A, down: true, modifiers: 0))
                sendInput(.key(hidUsage: 0x2A, down: false, modifiers: 0))
            } label: {
                Image(systemName: "delete.left")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.85))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.white.opacity(0.14)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Send Backspace to Mac")

            Button {
                commitWorkItem?.cancel()
                isShown = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.65))
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.white.opacity(0.10)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Hide Scribble bar")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(red: 0.11, green: 0.11, blue: 0.13).opacity(0.95))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                )
        )
        .padding(.horizontal, 18)
        .padding(.bottom, 12)
    }

    private func scheduleAutoFlush() {
        commitWorkItem?.cancel()
        guard autoSend, !text.isEmpty else { return }
        let item = DispatchWorkItem {
            flushText(withReturn: false)
        }
        commitWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65, execute: item)
    }

    private func flushText(withReturn: Bool) {
        commitWorkItem?.cancel()
        let current = text
        if !current.isEmpty {
            text = ""
            sendInput(.text(current))
        }
        if withReturn {
            // HID usage 0x28 = Return (Enter)
            sendInput(.key(hidUsage: 0x28, down: true, modifiers: 0))
            sendInput(.key(hidUsage: 0x28, down: false, modifiers: 0))
        }
    }
}

private struct ScribbleTextField: UIViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let onCommit: () -> Void
    let onEditingChanged: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UITextField {
        let tf = UITextField()
        tf.delegate = context.coordinator
        tf.textColor = .white
        tf.tintColor = UIColor(red: 0.35, green: 0.78, blue: 0.98, alpha: 1.0)
        tf.font = .systemFont(ofSize: 16, weight: .regular)
        tf.attributedPlaceholder = NSAttributedString(
            string: placeholder,
            attributes: [.foregroundColor: UIColor.white.withAlphaComponent(0.38)]
        )
        tf.backgroundColor = UIColor.white.withAlphaComponent(0.07)
        tf.layer.cornerRadius = 8
        tf.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 10, height: 1))
        tf.leftViewMode = .always
        tf.rightView = UIView(frame: CGRect(x: 0, y: 0, width: 10, height: 1))
        tf.rightViewMode = .always
        tf.autocorrectionType = .no
        tf.autocapitalizationType = .none
        tf.spellCheckingType = .no
        tf.returnKeyType = .send
        // Keep the software keyboard collapsed when Apple Pencil writes via Scribble
        tf.inputView = UIView(frame: .zero)
        tf.inputAssistantItem.leadingBarButtonGroups = []
        tf.inputAssistantItem.trailingBarButtonGroups = []
        tf.addTarget(context.coordinator, action: #selector(Coordinator.textChanged(_:)), for: .editingChanged)
        return tf
    }

    func updateUIView(_ uiView: UITextField, context: Context) {
        if uiView.text != text && uiView.markedTextRange == nil {
            uiView.text = text
        }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: ScribbleTextField

        init(_ parent: ScribbleTextField) {
            self.parent = parent
        }

        @objc func textChanged(_ sender: UITextField) {
            guard sender.markedTextRange == nil else { return }
            parent.text = sender.text ?? ""
            parent.onEditingChanged()
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            parent.onCommit()
            return false
        }
    }
}
