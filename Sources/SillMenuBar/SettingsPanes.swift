import AppKit
import Combine
import SwiftUI
import SillHostCore
import StreamProtocol

/// One Settings tab: a grouped Form, 520 pt wide. The controls bind straight to
/// `settings.config`, whose didSet is the one path to the host (see HostSettings).
struct SettingsPane: View {
    let tab: SettingsTab
    let model: AppModel
    /// The previews (DebugHooks): General's update section in this state instead of the live one,
    /// so a render does not depend on what an earlier run stored.
    var previewUpdates: UpdatePolicy.Pane?
    /// …and its clipboard section with macOS's answer as given, never read from this Mac.
    var previewClipboardAccess: ClipboardPolicy.MacAccess?
    /// …and what the macOS firewall does as given (FirewallRule), never asked.
    var previewFirewall: FirewallRule.Verdict?

    var body: some View {
        Group {
            switch tab {
            case .general: GeneralPane(model: model, settings: model.settings, previewUpdates: previewUpdates,
                                       previewClipboardAccess: previewClipboardAccess, previewFirewall: previewFirewall)
            case .devices: LiveDevicesPane(model: model, settings: model.settings)
            case .streaming: StreamingPane(model: model, settings: model.settings)
            case .virtualDisplay: VirtualDisplayPane(model: model, settings: model.settings)
            case .permissions: PermissionsPane(model: model)
            case .remoteAccess: LiveRemoteAccessPane(model: model, settings: model.settings)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        // Permissions and the login item change behind Sill's back, in System Settings. Re-read
        // them once a second, only while this tab is on screen, and when Sill becomes active; an
        // idle Sill with Settings closed wakes for nothing. The Devices and Remote Access panes
        // follow the host's status, which is pushed, so they poll nothing.
        .task(id: model.visibleSettingsTab == tab) {
            // General on screen: whether the macOS firewall blocks Sill, asked again (FirewallCheck).
            if model.visibleSettingsTab == tab, tab == .general { model.coordinator?.checkFirewall() }
            guard model.visibleSettingsTab == tab, tab != .streaming, tab != .devices, tab != .remoteAccess else { return }
            while !Task.isCancelled {
                model.permissions.refresh()
                model.loginItem.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.permissions.refresh()
            model.loginItem.refresh()
            // Back from Terminal with the command run: General's firewall line follows.
            if model.visibleSettingsTab == tab, tab == .general { model.coordinator?.checkFirewall() }
        }
    }
}

/// Footer text the way System Settings sets it: small, secondary, from the leading edge.
struct Footnote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// An orange problem line with its sign.
struct Warning: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A system error message inside a sentence of ours: without its own full stop.
func withoutFullStop(_ text: String) -> String {
    text.hasSuffix(".") ? String(text.dropLast()) : text
}

// MARK: General

private struct GeneralPane: View {
    let model: AppModel
    @Bindable var settings: HostSettings
    var previewUpdates: UpdatePolicy.Pane?
    var previewClipboardAccess: ClipboardPolicy.MacAccess?
    var previewFirewall: FirewallRule.Verdict?

    private static let runsFromApplications = Bundle.main.bundlePath.hasPrefix("/Applications/")

    var body: some View {
        Form {
            Section {
                Toggle("开机自动启动", isOn: Binding(get: { model.loginItem.isOn }, set: { model.loginItem.set($0) }))
                    .disabled(!model.loginItem.available)
                if !model.loginItem.available {
                    Footnote("仅当从应用程序包 (.app) 运行 Sill 时可用。")
                } else if model.loginItem.needsApproval {
                    LabeledContent("等待系统批准") {
                        Button("在系统设置中批准…") { model.loginItem.openSystemSettings() }
                    }
                }
                if let error = model.loginItem.error {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
            }
            Section {
                LabeledContent("运行位置") {
                    Text(Bundle.main.bundlePath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                if !Self.runsFromApplications {
                    Label("登录项和系统权限均绑定此 Sill 副本。建议仅在“应用程序”文件夹中保留一份副本。",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            Section {
                LabeledContent("局域网显示名称") { Text(networkName) }
            } footer: {
                HStack(spacing: 4) {
                    Text("这是此 Mac 的电脑名称。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("在“共享”设置中修改…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Sharing-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.link)
                    .font(.footnote)
                    Spacer(minLength: 0)
                }
            }
            // Beside the name devices see: the macOS firewall keeping them out (FirewallRule), only
            // while it does.
            if let firewall = previewFirewall ?? model.coordinator?.status.snapshot.firewall, firewall.blocksDevices {
                FirewallSection(verdict: firewall)
            }
            // How devices reach this Mac, so beside its name on the network. Applies at once without
            // restarting the stream (the listener is replaced); enabled in test pattern mode too,
            // where it is saved and changes only the listener.
            Section {
                Toggle("无线直连", isOn: $settings.config.directWireless)
            } footer: {
                Footnote("让附近的 iPad 或 iPhone 即使未连接同一 Wi\u{2011}Fi 也能像隔空投送 (AirDrop) 一样直连此 Mac。开启后 Wi\u{2011}Fi 串流可能偶尔出现卡顿。仅已配对的设备可以连接（除非关闭了“需要配对”）。")
            }
            // The clipboard both ways (HostClipboard): at once, no restart. Each device has its own
            // switch too. macOS's answer is read with the permissions (once a second while this pane
            // shows, and when Sill becomes active), never in a preview.
            ClipboardSection(shareClipboard: $settings.config.shareClipboard,
                             access: previewClipboardAccess ?? model.permissions.clipboardAccess,
                             allow: { model.permissions.allowClipboard() })
            if let preview = previewUpdates {
                UpdatesSection(pane: preview, automatic: .constant(true))
            } else {
                UpdatesSection(pane: model.updates.pane, automatic: $settings.updateCheck,
                               actions: UpdatesSection.Actions(checkNow: { model.updates.checkNow() },
                                                               openRelease: { NSWorkspace.shared.open($0) }))
            }
            Section {
                HStack {
                    Button("查看日志…") { model.showLog?() }
                    Button("在访达中显示日志文件") {
                        if let url = HostLog.shared.fileURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    }
                    .disabled(HostLog.shared.fileURL == nil)
                }
            }
            Section {
                // A way out when the status item is hidden (a crowded menu bar, the notch).
                Button("退出 Sill") { NSApp.terminate(nil) }
            } footer: {
                Footnote("Sill \(AppModel.version) (\(AppModel.build)) · 免费开源软件。")
            }
        }
    }

    private var networkName: String {
        let snapshot = model.coordinator?.status.snapshot ?? HostStatusSnapshot()
        switch snapshot.network {
        case .advertising(let name): return "“\(name)”"
        case .notAdvertised: return "未广播（测试画面模式）"
        case .failed: return "不可见（监听器启动失败）"
        case .waiting: return "暂不可见（正在等待网络）"
        case .starting, .registering: return "正在注册…"
        }
    }
}

// MARK: Firewall

/// The macOS firewall keeps devices out (FirewallRule; a user's report of 2026-10-29), in the
/// Permissions pane's style: what it blocks and why that matters, then the Terminal command that
/// unblocks Sill, the running executable's path in it, with Copy; or, for Block all incoming
/// connections, where to turn it off. Nothing while the firewall lets devices in. Sill never runs the
/// command itself (it needs an administrator). Drawn alone in the previews in each verdict.
struct FirewallSection: View {
    let verdict: FirewallRule.Verdict
    @State private var copied = false

    var body: some View {
        if let line = FirewallRule.Copy.paneLine(verdict) {
            let command = FirewallRule.Copy.command(verdict)
            Section {
                LabeledContent {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        if let command {
                            Button(copied ? "已拷贝" : "拷贝") { copy(command) }
                                .help("拷贝命令以粘贴到终端运行")
                        }
                    }
                } label: {
                    Text("防火墙")
                    Text(line)
                }
                if let lines = FirewallRule.Copy.commandLines(verdict) {
                    // A line for the tool and one for each option, never "--" over "unblockapp".
                    Text(verbatim: lines.joined(separator: "\n"))
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(command ?? "")
                }
            }
        }
    }

    /// The command onto the clipboard, and "Copied" on the button for 2 s (VoiceOver hears it).
    private func copy(_ command: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        copied = true
        AccessibilityNotification.Announcement("Copied").post()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}

// MARK: Clipboard

/// Share clipboard with devices (HostClipboard, docs/clipboard-plan.md): the switch and its footnote,
/// and while the switch is on and macOS does not allow every read Sill makes on its own
/// (ClipboardPolicy.MacAccess), why what is copied here stays on this Mac and the way to allow it.
/// Drawn alone in the previews in each of macOS's answers (DebugHooks).
struct ClipboardSection: View {
    @Binding var shareClipboard: Bool
    let access: ClipboardPolicy.MacAccess
    var allow: () -> Void = {}

    var body: some View {
        Section {
            Toggle("与设备共享剪贴板", isOn: $shareClipboard)
            if shareClipboard, let warning = ClipboardPolicy.Copy.macAccessWarning(access) {
                VStack(alignment: .leading, spacing: 6) {
                    Warning(warning)
                    if let hint = ClipboardPolicy.Copy.macAccessHint(access) {
                        Text(hint)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button(ClipboardPolicy.Copy.macAccessButton, action: allow)
                }
            }
        } footer: {
            Footnote(ClipboardPolicy.Copy.macFootnote)
        }
    }
}

// MARK: Updates

/// Settings › General's update check: the automatic switch, the line (what the last check found, or
/// why Sill cannot check), Open Release Page… while a newer release is offered, and Check Now. Plain
/// values in, so the previews draw every state. Errors show here and in the log, never in an alert.
struct UpdatesSection: View {
    struct Actions {
        var checkNow: () -> Void = {}
        var openRelease: (URL) -> Void = { _ in }
    }

    let pane: UpdatePolicy.Pane
    @Binding var automatic: Bool
    var actions = Actions()

    var body: some View {
        Section {
            Toggle("自动检查更新", isOn: $automatic)
            LabeledContent {
                HStack(spacing: 8) {
                    if let url = pane.releasePage {
                        Button("打开发布页面…") { actions.openRelease(url) }
                    }
                    Button("立即检查") { actions.checkNow() }
                        .disabled(!pane.canCheck)
                }
            } label: {
                Text(pane.line)
                    .foregroundStyle(pane.failed ? Color.orange : Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // VoiceOver hears Check Now's result, which arrives after the click.
            .onChange(of: pane.resultID) { _, _ in
                AccessibilityNotification.Announcement(pane.line).post()
            }
        } footer: {
            Footnote(UpdatePolicy.footnote)
        }
    }
}

// MARK: Streaming

private struct StreamingPane: View {
    let model: AppModel
    @Bindable var settings: HostSettings

    var body: some View {
        Form {
            Section {
                Picker("帧率上限", selection: $settings.config.maxFPS) {
                    Text("60 fps").tag(60)
                    Text("120 fps").tag(120)
                }
                .pickerStyle(.segmented)
                Picker("画质", selection: $settings.config.bitrate) {
                    ForEach(QualityPreset.allCases) { Text($0.title).tag($0.rawValue) }
                    if QualityPreset(rawValue: settings.config.bitrate) == nil {
                        Text(QualityPreset.title(forBitrate: settings.config.bitrate)).tag(settings.config.bitrate)
                    }
                }
                Picker("分辨率", selection: $settings.config.captureScale) {
                    Text("视网膜 (Retina)").tag(CGFloat(2))
                    Text("标准").tag(CGFloat(1))
                }
            } footer: {
                Footnote("每台设备会按自身屏幕刷新率请求帧率（不超过此上限）。画质按 60 fps 计算；120 fps 串流码率翻倍。修改后立即生效。")
            }
            // Away from home (docs/remote-bundle-plan.md §5): its own quality, which a device away
            // sets too; the menu's Quality and Resolution stay the home ones.
            Section {
                Picker("画质", selection: $settings.config.awayBitrate) {
                    ForEach(QualityPreset.allCases) { Text($0.title).tag($0.rawValue) }
                    if QualityPreset(rawValue: settings.config.awayBitrate) == nil {
                        Text(QualityPreset.title(forBitrate: settings.config.awayBitrate)).tag(settings.config.awayBitrate)
                    }
                }
                Picker("分辨率", selection: $settings.config.awayCaptureScale) {
                    Text("视网膜 (Retina)").tag(CGFloat(2))
                    Text("标准").tag(CGFloat(1))
                }
            } header: {
                Text("远程网络（异地连接）")
            } footer: {
                Footnote("当连接的设备均通过 VPN 或互联网远程访问时，使用此画质与分辨率，避免慢速网络下直接以局域网高码率启动。"
                         + (model.coordinator?.status.snapshot.away == true ? " 当前正在使用此套参数串流。" : ""))
            }
            Section {
                Toggle("优先保证编码速度", isOn: $settings.config.prioritizeSpeed)
            } footer: {
                Footnote("在 Mac 高负载时降低画面延迟，画面细节会略微柔和。")
            }
            // The Mac's sound (docs/audio-plan.md §6), a beta: its switch and its footnote say so. A device's
            // Settings panel turns it on and off too, for every device, and mutes it for that device alone
            // (Q8 as Noah revised it on 2026-10-27).
            Section {
                Toggle("发送音频（测试版）", isOn: $settings.config.sendAudio)
                if settings.config.sendAudio, let problem = model.coordinator?.status.snapshot.audio?.problem {
                    Warning("Sill \(problem)。画面传输不受影响。")
                }
            } footer: {
                Footnote("测试版功能。将所选应用窗口或整个桌面的声音同步传输到 iPad/iPhone，Mac 本机也会继续播放声音。已连接的设备可在其设置面板中单独静音。")
            }
            if let snapshot = model.coordinator?.status.snapshot, snapshot.softwareEncoder {
                Section {
                    Label(snapshot.hardwareEncoderStuck
                          ? "硬件编码器卡住，当前使用软件编码（最高 60 fps、标准分辨率）。重启 Mac 可修复此问题。"
                          : "硬件编码器繁忙或无响应，当前使用软件编码（最高 60 fps、标准分辨率）。恢复空闲后将自动切回硬件编码。",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
        }
    }
}

// MARK: Virtual Display

private struct VirtualDisplayPane: View {
    let model: AppModel
    @Bindable var settings: HostSettings
    @State private var retrying = false

    var body: some View {
        let snapshot = model.coordinator?.status.snapshot ?? HostStatusSnapshot()
        Form {
            Section {
                Toggle("使用虚拟显示器串流单窗口", isOn: $settings.config.virtualDisplay)
            } footer: {
                Footnote("Sill 会将你在 iPad 上选中的单个应用窗口移至专门创建的隐藏虚拟显示器上，这样即使 Mac 上有其他窗口遮挡也能持续刷新，并按 iPad 屏幕比例清晰渲染。停止串流或退出 Sill 时窗口会自动移回原屏幕。")
            }
            Section {
                LabeledContent("状态") {
                    HStack(spacing: 8) {
                        Text(statusText(snapshot))
                            .multilineTextAlignment(.trailing)
                        if canRetry(snapshot) {
                            Button("重试") {
                                retrying = true
                                Task { @MainActor in
                                    await model.coordinator?.retryVirtualDisplay()
                                    retrying = false
                                }
                            }
                            .disabled(retrying || model.coordinator == nil)
                        }
                    }
                }
                if settings.config.virtualDisplay, let failure = snapshot.lastStageFailure {
                    LabeledContent("最近窗口") {
                        Text("在原屏幕串流：\(failure)").multilineTextAlignment(.trailing)
                    }
                }
            } footer: {
                Footnote("使用 macOS 私有接口 (CGVirtualDisplay)。若系统更新导致不可用，Sill 会自动回退为直接在原屏幕捕获窗口。")
            }
        }
    }

    private func statusText(_ s: HostStatusSnapshot) -> String {
        let sr = model.permissions.screenRecording, ax = model.permissions.accessibility
        if s.virtualDisplayAPIMissing, let problem = s.virtualDisplayProblem {
            return "当前 macOS 版本不可用：\(problem)"
        }
        if !sr && !ax { return "需要“录屏与系统录音”和“辅助功能”权限" }
        if !ax { return "需要“辅助功能”权限" }
        if !sr { return "需要“录屏与系统录音”权限" }
        if let problem = s.virtualDisplayProblem { return "本次会话已停用：\(problem)" }
        return "可用"
    }

    /// A run-level disable (the system removed the display too often) can be retried; a missing
    /// API or permission cannot.
    private func canRetry(_ s: HostStatusSnapshot) -> Bool {
        s.virtualDisplayProblem != nil && !s.virtualDisplayAPIMissing && model.permissions.allGranted
    }
}

// MARK: Permissions

private struct PermissionsPane: View {
    let model: AppModel

    var body: some View {
        let permissions = model.permissions
        let network = model.coordinator?.status.snapshot.network
        Form {
            Section {
                PermissionRow(title: "录屏与系统录音", allowed: permissions.screenRecording,
                              // Not "on this network": a device connected over Direct Wireless shares none.
                              explanation: "允许 Sill 捕获你在 iPad 或 iPhone 上选择的 Mac 窗口或桌面画面（以及开启“发送音频”时的系统声音）。所有画面与声音仅实时传输给你的设备，绝不录制或保存。",
                              button: model.settings.askedScreenRecording ? "打开系统设置…" : "授权…") {
                    permissions.requestScreenRecording()
                }
                PermissionRow(title: "辅助功能", allowed: permissions.accessibility,
                              explanation: "允许 iPad 或 iPhone 在此 Mac 上点击、滚动、使用 Apple Pencil 压感绘画以及手写/键盘输入文字，并允许调整串流窗口大小。",
                              button: model.settings.askedAccessibility ? "打开系统设置…" : "授权…") {
                    permissions.requestAccessibility()
                }
            } footer: {
                Footnote("权限绑定于 Sill 应用本身。")
            }
            if permissions.relaunchSuggested, !permissions.screenRecording {
                Section {
                    LabeledContent("重新打开 Sill 后录屏权限即可生效。") {
                        Button(permissions.canRelaunch ? "重新打开 Sill" : "退出 Sill") { permissions.relaunch() }
                    }
                }
            }
            if Self.networkNeedsHelp(network) {
                Section {
                    LabeledContent {
                        Button("打开本地网络设置…") { permissions.openPrivacyPane("Privacy_LocalNetwork") }
                    } label: {
                        Text("本地网络")
                        Text("如果 iPad 或 iPhone 找不到此 Mac，请在“隐私与安全性 › 本地网络”中允许 Sill。")
                    }
                }
            }
            if permissions.allGranted {
                Section {
                    Label("权限已全部就绪！请在 iPad 或 iPhone 上打开 Sill 连接。", systemImage: "checkmark.seal.fill")
                }
            }
        }
    }

    private static func networkNeedsHelp(_ network: HostStatusSnapshot.Network?) -> Bool {
        switch network {
        case .waiting, .failed: return true
        default: return false
        }
    }
}

private struct PermissionRow: View {
    let title: String
    let allowed: Bool
    let explanation: String
    let button: String
    let action: () -> Void

    var body: some View {
        LabeledContent {
            if allowed {
                Label("已授权", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Button(button, action: action)
                }
            }
        } label: {
            Text(title)
            Text(explanation)
        }
    }
}
