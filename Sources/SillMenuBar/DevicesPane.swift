import AppKit
import SwiftUI
import SillHostCore
import StreamProtocol

/// Settings › Devices, live: Require pairing, which the model keeps in the identity store beside
/// the trust list (never in UserDefaults), the pairing window's switch for screen sharing (in
/// UserDefaults, HostSettings), and the paired devices from the host's status (pushed, so nothing
/// polls), with the model's actions.
struct LiveDevicesPane: View {
    let model: AppModel
    @Bindable var settings: HostSettings

    var body: some View {
        DevicesPane(status: model.coordinator?.status.snapshot.remote ?? RemoteStatus(),
                    requirePairing: Binding(get: { settings.config.requirePairing }, set: { model.setRequirePairing($0) }),
                    showPairingWindowToScreenSharing: $settings.showPairingWindowToScreenSharing,
                    requirePairingProblem: model.requirePairingProblem,
                    actions: DevicesPane.Actions(pair: { model.pairDevice() },
                                                 remove: { model.removeDevice($0) },
                                                 rename: { model.renameDevice($0, to: $1) }))
    }
}

/// The Devices pane (docs/home-pairing-plan.md §6.1): Require pairing; Show the pairing window to
/// screen sharing (issue #108, PairingWindowSharing); and the devices paired with this Mac at home
/// and from afar (one trust list), each with how it paired and how it last connected, Remove, rename
/// and Pair iPhone or iPad…. Values in, actions out, so the previews can draw every state. Errors
/// show inline, never in alerts.
struct DevicesPane: View {
    struct Actions {
        var pair: () -> Void = {}
        /// Nil when the device was removed; otherwise why it is still paired.
        var remove: (String) -> String? = { _ in nil }
        var rename: (String, String) -> Void = { _, _ in }
    }

    let status: RemoteStatus
    @Binding var requirePairing: Bool
    /// Screen Sharing and other remote desktop apps show the pairing window (off by default).
    @Binding var showPairingWindowToScreenSharing: Bool
    /// The last Require pairing change the identity store did not keep.
    var requirePairingProblem: AppModel.RequirePairingProblem?
    let actions: Actions
    /// "Last connected 2 minutes ago" counts from here (fixed in the previews).
    var now: Date?

    @State private var removedName: String?
    /// A Remove the keychain did not keep: the device's name and why.
    @State private var removeProblem: (name: String, reason: String)?

    /// Why devices can't connect at all: the identity (the key, the trust list) could not be used,
    /// so the home door has no listener. Nil when it works.
    private var unavailable: String? {
        if let problem = status.identityProblem { return problem }
        if case .unavailable(let why) = status.homeDoor { return why }
        return nil
    }

    var body: some View {
        Form {
            Section {
                Toggle("需要配对", isOn: $requirePairing)
                    .disabled(unavailable != nil)
                if let problem = unavailable {
                    Warning("设备无法连接：Sill 无法访问钥匙串中的密钥（\(withoutFullStop(problem))）。请退出并重新打开 Sill，若弹出钥匙串提示请选择“始终允许”。")
                } else if let p = requirePairingProblem {
                    let reason = withoutFullStop(p.reason)
                    Warning(p.wanted
                            ? "在退出 Sill 前仍需配对：无法更新钥匙串（\(reason)），请重试。"
                            : "仍保持需要配对状态：无法更新钥匙串（\(reason)），请重试。")
                }
            } footer: {
                if requirePairing {
                    Footnote("每台 iPad 或 iPhone 只需配对一次：通过 USB 数据线连接会自动完成配对，通过 Wi\u{2011}Fi 连接则扫描或输入此 Mac 显示的配对码。所有传输内容均全程加密。")
                } else {
                    Label("同一局域网内（或开启“无线直连”时附近）的任何设备无需配对即可看到并控制此 Mac。传输仍保持加密。",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Section {
                Toggle("向屏幕共享显示配对窗口", isOn: $showPairingWindowToScreenSharing)
            } footer: {
                Footnote("当你通过“屏幕共享”或其他远程桌面软件操作此 Mac 时开启此项，以便看到配对码窗口。")
            }
            pairedDevices
        }
    }

    private var pairedDevices: some View {
        Section {
            if let removedName {
                Text("“\(removedName)”已无法连接。如需再次使用，请重新配对。")
            }
            if let removeProblem {
                Warning("“\(removeProblem.name)”仍处于已配对状态：Sill 无法更新钥匙串（\(withoutFullStop(removeProblem.reason))），请重试。")
            }
            if unavailable != nil {
                // The trust list lives with the key: unread, not empty.
                Text("待 Sill 重新获得钥匙串密钥访问权限后，此处将显示已配对设备。").foregroundStyle(.secondary)
            } else if status.paired.isEmpty {
                Text("暂无已配对设备。").foregroundStyle(.secondary)
            }
            ForEach(status.paired) { device in
                PairedDeviceRow(device: device, now: now,
                                remove: {
                                    // Said only once the keychain kept it: otherwise the device
                                    // would be trusted again at the next launch.
                                    if let reason = actions.remove(device.id) {
                                        removedName = nil
                                        removeProblem = (device.name, reason)
                                    } else {
                                        removedName = device.name
                                        removeProblem = nil
                                    }
                                },
                                rename: { actions.rename(device.id, $0) })
            }
            Button("配对 iPhone 或 iPad…") { actions.pair() }
                .disabled(unavailable != nil)
        } header: {
            Text("已配对设备")
        } footer: {
            Footnote("已配对设备可在局域网、附近无线直连或开启“远程访问”时连接并控制此 Mac。双击设备名称可重命名。")
        }
    }
}

/// One paired device: its name (double-click to rename: Return saves, Esc cancels), how it paired,
/// when and how it last connected (at home or from away), and Remove, with no confirmation since
/// it only takes access away.
struct PairedDeviceRow: View {
    let device: PairedDeviceSummary
    let now: Date?
    let remove: () -> Void
    let rename: (String) -> Void

    @State private var editing = false
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        LabeledContent {
            Button("移除", action: remove)
        } label: {
            if editing {
                TextField("名称", text: $text)
                    .focused($focused)
                    .onSubmit {
                        rename(text)
                        editing = false
                    }
                    .onExitCommand { editing = false }
            } else {
                Text(device.name)
                    .onTapGesture(count: 2) { startEditing() }
                    .accessibilityAction(named: "重命名") { startEditing() }
            }
            Text(Self.detail(device, now: now ?? Date()))
        }
    }

    private func startEditing() {
        text = device.name
        editing = true
        focused = true
    }

    /// "Paired Sep 25 over the USB cable · last connected 2 minutes ago over Wi‑Fi", "Paired Sep 24
    /// with the QR code · last connected yesterday through Tailscale".
    static func detail(_ device: PairedDeviceSummary, now: Date) -> String {
        var out = "配对于 \(day(device.pairedAt, now: now))"
        if let method = device.displayMethod { out += " (\(method))" }
        if let seen = device.lastSeen {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            formatter.dateTimeStyle = .named
            let when = now.timeIntervalSince(seen) < 60 ? "刚刚" : formatter.localizedString(for: seen, relativeTo: now)
            out += " · 上次连接：\(when)"
            if let route = device.lastRoute { out += " (\(route))" }
        }
        return out
    }

    static func day(_ date: Date, now: Date) -> String {
        let sameYear = Calendar.current.component(.year, from: date) == Calendar.current.component(.year, from: now)
        return sameYear ? date.formatted(.dateTime.month(.abbreviated).day()) : date.formatted(.dateTime.month(.abbreviated).day().year())
    }
}
