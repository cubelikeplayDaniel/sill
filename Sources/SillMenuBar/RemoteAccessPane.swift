import AppKit
import SwiftUI
import SillHostCore
import StreamProtocol

/// Settings › Remote Access, live: the host's remote status (pushed, so nothing polls) and the
/// app's settings, with the model's actions.
struct LiveRemoteAccessPane: View {
    let model: AppModel
    @Bindable var settings: HostSettings

    var body: some View {
        RemoteAccessPane(status: model.coordinator?.status.snapshot.remote ?? RemoteStatus(),
                         remoteAccess: $settings.config.remoteAccess,
                         internetAccess: $settings.config.internetAccess,
                         port: settings.config.remotePort,
                         addressName: settings.remoteAddressName,
                         actions: RemoteAccessPane.Actions(
                             setPort: { settings.config.remotePort = $0 },
                             setAddressName: { settings.remoteAddressName = $0 },
                             showDevices: { model.showSettings?(.devices) }))
    }
}

/// The Remote Access pane (docs/remote-access-plan.md §6.1): the switch, the Mac's addresses and
/// its port, how many devices are paired (the list itself is in Settings › Devices,
/// docs/home-pairing-plan.md §6.2), the internet switch, and sleep. Values in, actions out, so the
/// previews can draw every state. Errors show inline, never in alerts.
struct RemoteAccessPane: View {
    struct Actions {
        var setPort: (Int) -> Void = { _ in }
        var setAddressName: (String) -> Void = { _ in }
        /// Show Devices…: Settings on the Devices tab.
        var showDevices: () -> Void = {}
    }

    let status: RemoteStatus
    @Binding var remoteAccess: Bool
    @Binding var internetAccess: Bool
    /// The configured port (the app's is never 0).
    let port: Int
    /// The address name setting, as saved.
    let addressName: String
    let actions: Actions

    @State private var editingPort = false
    @State private var portText = ""
    @State private var portSaved = false
    @State private var nameText: String?
    @State private var nameProblem: String?

    private var available: Bool { status.identityProblem == nil }
    private var on: Bool { remoteAccess && available }

    var body: some View {
        Form {
            Section {
                Toggle("启用远程访问", isOn: $remoteAccess)
                    .disabled(!available)
                if let problem = status.identityProblem {
                    // The system's messages end with a full stop of their own.
                    let reason = problem.hasSuffix(".") ? String(problem.dropLast()) : problem
                    Warning("远程访问不可用：Sill 无法访问钥匙串（\(reason)）。")
                }
            } footer: {
                Footnote("允许已配对的 iPad 或 iPhone 从其他网络（如通过 Tailscale 等 VPN 或路由器端口转发）远程连接此 Mac。所有未配对设备均会被拒绝，传输全程加密。")
            }
            if on { addresses }
            pairedDevices
            if on { internet }
            Section {
                LabeledContent {
                    Button("打开电池/节能设置…") { Self.openEnergySettings() }
                } label: {
                    Text("休眠")
                    Text("Mac 休眠期间无法被远程唤醒或连接。当有远程设备连接时，Sill 会自动阻止 Mac 进入休眠。")
                }
            }
        }
    }

    // MARK: Addresses

    @ViewBuilder private var addresses: some View {
        let rows = Self.addressRows(status.addresses)
        Section {
            switch status.listener {
            case .portInUse(let p):
                LabeledContent {
                    Button("修改…") { startEditingPort() }
                } label: {
                    Warning("端口 \(p) 已被其他应用占用，设备无法远程连接此 Mac。Sill 每 30 秒会自动重试。")
                }
            case .failed(let error):
                Warning("远程访问无法启动（\(error)）。Sill 每 30 秒会自动重试。")
            case .off, .listening:
                EmptyView()
            }
            ForEach(rows) { row in
                LabeledContent {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(row.primary).textSelection(.enabled)
                            if !row.others.isEmpty {
                                Text(row.others.joined(separator: " · "))
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                        CopyButton(text: row.primary, spoken: "拷贝 \(row.label) 地址")
                    }
                } label: {
                    Text(row.label)
                    if row.lan {
                        Text("当前局域网地址。可配合连入家庭网络的 VPN（如路由器上的 WireGuard）使用。")
                    }
                }
            }
            ForEach(status.vpnDown, id: \.self) { name in
                Text("\(name) — 未连接").foregroundStyle(.secondary)
            }
            if !rows.contains(where: { $0.vpn }) && status.vpnDown.isEmpty {
                Text("此 Mac 未运行 VPN。可在此 Mac 及 iPad/iPhone 上安装 Tailscale 等组网工具，或在下方开启互联网直连。")
                    .foregroundStyle(.secondary)
            }
            portRow
        } header: {
            Text("地址")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(status.vpnDown, id: \.self) { name in
                    Footnote("在 \(name) 连接前，设备无法通过它访问此 Mac。")
                }
                Footnote("设备在配对时会自动记住这些地址，并在每次连接时自动更新。")
            }
        }
    }

    @ViewBuilder private var portRow: some View {
        if editingPort {
            let problem = Self.portProblem(portText)
            LabeledContent("端口") {
                HStack(spacing: 8) {
                    TextField("端口", text: $portText)
                        .labelsHidden()
                        .frame(width: 72)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .onSubmit { savePort() }
                        .onExitCommand { editingPort = false }
                    Button("保存") { savePort() }
                        .disabled(problem?.blocks ?? false)
                        .keyboardShortcut(.defaultAction)
                    Button("取消") { editingPort = false }
                }
            }
            if let problem {
                if problem.blocks { Warning(problem.message) } else { Text(problem.message).foregroundStyle(.secondary) }
            }
        } else {
            LabeledContent("端口") {
                HStack(spacing: 8) {
                    Text(String(port)).monospacedDigit().textSelection(.enabled)
                    Button("修改…") { startEditingPort() }
                }
            }
            if portSaved {
                Text("已配对设备将在下次局域网连接时自动更新此端口。").foregroundStyle(.secondary)
            }
        }
    }

    private func startEditingPort() {
        portText = String(port)
        portSaved = false
        editingPort = true
    }

    private func savePort() {
        if let problem = Self.portProblem(portText), problem.blocks { return }
        guard let p = Int(portText.trimmingCharacters(in: .whitespaces)) else { return }
        editingPort = false
        if p != port {
            actions.setPort(p)
            portSaved = true
        }
    }

    /// What is wrong with a port typed into the field: blocking (it cannot be saved), or only a
    /// warning. Nil when it is fine.
    static func portProblem(_ text: String) -> (message: String, blocks: Bool)? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t.allSatisfy({ $0.isASCII && $0.isNumber }), t.count <= 5, let p = Int(t), (1024...65535).contains(p) else {
            return ("请填写 1024 到 65535 之间的端口号。", true)
        }
        if p == 5000 || p == 7000 { return ("端口 \(p) 已被“隔空播放接收器”占用，请换用其他端口。", true) }
        if p >= 49152 { return ("49152 以上的临时端口随时可能被系统分配给其他应用。", false) }
        return nil
    }

    // MARK: Paired devices

    /// One row: the list, Remove and Pair iPhone or iPad… are in Settings › Devices, since the same
    /// devices connect at home too.
    private var pairedDevices: some View {
        Section {
            LabeledContent("已配对设备") {
                HStack(spacing: 8) {
                    Text(status.paired.isEmpty ? "无" : "\(status.paired.count) 台").monospacedDigit()
                    Button("管理设备…") { actions.showDevices() }
                }
            }
        } footer: {
            Footnote("在“设备”页完成配对的设备可在远程访问开启时从外网连接。")
        }
    }

    // MARK: Internet

    private var internet: some View {
        Section {
            Toggle("允许来自互联网的连接", isOn: $internetAccess)
            if internetAccess {
                if let lan = status.lanAddress {
                    LabeledContent {
                        CopyButton(text: lan, spoken: "拷贝此 Mac 的局域网地址")
                    } label: {
                        Text("请在路由器设置中将 TCP 端口 \(String(port)) 转发至此 Mac (\(lan))，并为本机绑定固定局域网 IP。")
                    }
                }
                routerRow
                addressNameRow
                if let v6 = status.addresses.first(where: { $0.kind == MacAddress.internet && $0.via == "IPv6" }) {
                    LabeledContent {
                        HStack(spacing: 8) {
                            Text(v6.host).textSelection(.enabled)
                            CopyButton(text: v6.host, spoken: "拷贝 IPv6 地址")
                        }
                    } label: {
                        Text("IPv6")
                        Text("仅当路由器防火墙允许外部 IPv6 入站连接到此 Mac 时可用。")
                    }
                }
            }
        } header: {
            Text("互联网")
        } footer: {
            if internetAccess {
                Footnote("互联网上的任何人均能探测端口 \(String(port))，但 Sill 会拒绝所有未配对设备的连接。")
            } else {
                Footnote("仅在通过路由器端口转发连接时需要开启。推荐使用 Tailscale 等 VPN，无需暴露公网端口。")
            }
        }
    }

    @ViewBuilder private var routerRow: some View {
        switch status.router {
        case .off:
            EmptyView()
        case .asking:
            LabeledContent("路由器公网地址") { Text("正在查询路由器…").foregroundStyle(.secondary) }
        case .address(let a):
            LabeledContent("路由器公网地址") {
                HStack(spacing: 8) {
                    Text(a).textSelection(.enabled)
                    CopyButton(text: a, spoken: "拷贝路由器公网地址")
                }
            }
        case .carrierNAT(let a):
            LabeledContent("路由器公网地址") {
                Warning("宽带运营商使用了内网共享地址 (\(Self.masked(a)))，路由器端口转发无法从外网直达此 Mac。请改用 Tailscale 等 VPN。")
            }
        case .doubleNAT:
            LabeledContent("路由器公网地址") {
                Warning("当前路由器处于二级路由下（双重 NAT），需在两级路由器上同时转发端口，或改用 VPN。")
            }
        case .noAnswer:
            LabeledContent("路由器公网地址") {
                Text("路由器未返回公网地址，请在路由器管理后台查看。").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var addressNameRow: some View {
        LabeledContent {
            TextField("域名地址", text: Binding(get: { nameText ?? addressName }, set: { nameText = $0; nameProblem = nil }),
                      prompt: Text("home.example.net"))
                .labelsHidden()
                .frame(width: 220)
                .onSubmit { saveAddressName() }
        } label: {
            Text("动态域名 DDNS（可选）")
            Text("如果路由器配置了动态域名 (DDNS)，请在此填入，以便公网 IP 变动后设备仍能找到此 Mac。")
        }
        if let nameProblem { Warning(nameProblem) }
    }

    private func saveAddressName() {
        let text = (nameText ?? addressName).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { nameProblem = nil; actions.setAddressName(""); return }
        switch AddressParser.parse(text) {
        case .success:
            nameProblem = nil
            actions.setAddressName(text)
        case .failure(.zone):
            nameProblem = "请移除 % 及其后面的部分（仅限本地链路使用）。"
        case .failure:
            nameProblem = "地址格式有误，请输入如 home.example.net 或 home.example.net:17455。"
        }
    }

    // MARK: Helpers

    /// One row per way in: the service's name, the name devices dial first (a MagicDNS name) and
    /// the addresses behind it. Internet addresses have their own section.
    struct AddressRow: Identifiable {
        var id: String { label }
        var label: String
        var primary: String
        var others: [String]
        var vpn: Bool
        var lan: Bool
    }

    static func addressRows(_ addresses: [MacAddress]) -> [AddressRow] {
        var order: [String] = []
        var byVia: [String: [MacAddress]] = [:]
        for a in addresses where a.kind != MacAddress.internet {
            if byVia[a.via] == nil { order.append(a.via) }
            byVia[a.via, default: []].append(a)
        }
        return order.compactMap { via in
            guard let list = byVia[via] else { return nil }
            let isName: (MacAddress) -> Bool = { a in
                if case .success(let p) = AddressParser.parse(a.host) { return p.kind == .name }
                return false
            }
            let sorted = list.filter(isName) + list.filter { !isName($0) }
            guard let first = sorted.first else { return nil }
            return AddressRow(label: via, primary: first.host, others: sorted.dropFirst().map(\.host),
                              vpn: list.contains { $0.kind == MacAddress.vpn },
                              lan: list.allSatisfy { $0.kind == MacAddress.lan } && via != "This Mac")
        }
    }

    /// "100.72.x.x": a shared carrier address says nothing useful beyond its first half.
    static func masked(_ address: String) -> String {
        let parts = address.split(separator: ".")
        guard parts.count == 4 else { return address }
        return "\(parts[0]).\(parts[1]).x.x"
    }

    /// Battery on a laptop, Energy on a desktop: one System Settings extension on macOS 27
    /// (/System/Library/ExtensionKit/Extensions/PowerPreferences.appex).
    static func openEnergySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Copy, then "Copied" for 1.5 s.
private struct CopyButton: View {
    let text: String
    let spoken: String
    @State private var copied = false

    var body: some View {
        Button(copied ? "已拷贝" : "拷贝") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        }
        .accessibilityLabel(copied ? "已拷贝" : spoken)
    }
}
