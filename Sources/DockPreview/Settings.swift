import AppKit
import ApplicationServices
import SwiftUI
import ServiceManagement

final class Settings: ObservableObject {
    @Published var delay: Double { didSet { UserDefaults.standard.set(delay, forKey: "hoverDelay") } }
    @Published var cardWidth: Double { didSet { UserDefaults.standard.set(cardWidth, forKey: "cardWidth") } }
    @Published var exclusions: String { didSet { UserDefaults.standard.set(exclusions, forKey: "exclusions") } }
    @Published var paused = false
    init() {
        let defaults = UserDefaults.standard
        delay = defaults.object(forKey: "hoverDelay") == nil ? 0.25 : defaults.double(forKey: "hoverDelay")
        cardWidth = defaults.object(forKey: "cardWidth") == nil ? 220 : defaults.double(forKey: "cardWidth")
        exclusions = defaults.string(forKey: "exclusions") ?? ""
    }
    func excludes(_ app: NSRunningApplication) -> Bool {
        Set(exclusions.split(whereSeparator: { $0 == "\n" || $0 == "," }).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }).contains(app.bundleIdentifier ?? "")
    }
}

struct SettingsView: View {
    @ObservedObject var settings: Settings
    @State private var accessibility = AXIsProcessTrusted()
    @State private var recording = CGPreflightScreenCaptureAccess()
    @State private var login = SMAppService.mainApp.status == .enabled
    @State private var message = ""
    let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Dock Preview").font(.title2.bold())
                    Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("悬停 Dock 图标，选择或关闭窗口。预览仅保存在内存中。")
                    .foregroundStyle(.secondary)
            }
            GroupBox("权限") {
                VStack(alignment: .leading, spacing: 10) {
                permissionRow("辅助功能", enabled: accessibility) {
                    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                    _ = AXIsProcessTrustedWithOptions(options)
                    openPrivacy("Privacy_Accessibility")
                }
                permissionRow("屏幕录制", enabled: recording) {
                    _ = CGRequestScreenCaptureAccess()
                    recording = CGPreflightScreenCaptureAccess()
                    if !recording { openPrivacy("Privacy_ScreenCapture") }
                }
                Text("辅助功能用于识别和操作窗口；屏幕录制用于缩略图。未授权屏幕录制时仍可使用标题列表。授权后若截图不可用，请退出并重新打开应用。")
                    .font(.caption).foregroundStyle(.secondary)
                }.padding(6)
            }
            GroupBox("交互") {
                VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("悬停延迟")
                    Slider(value: $settings.delay, in: 0.15...0.8, step: 0.05)
                    Text("\(Int(settings.delay * 1000)) ms").monospacedDigit().frame(width: 65)
                }
                HStack {
                    Text("卡片宽度")
                    Slider(value: $settings.cardWidth, in: 180...300, step: 20)
                    Text("\(Int(settings.cardWidth)) pt").monospacedDigit().frame(width: 65)
                }
                Toggle("暂停预览", isOn: $settings.paused)
                Toggle("登录时启动", isOn: $login).onChange(of: login) { _, value in
                    do {
                        if value { try SMAppService.mainApp.register() }
                        else { try SMAppService.mainApp.unregister() }
                        if SMAppService.mainApp.status == .requiresApproval {
                            message = "请在系统设置 → 通用 → 登录项中允许启动。"
                            SMAppService.openSystemSettingsLoginItems()
                        } else { message = "" }
                    } catch {
                        message = "登录启动设置失败：\(error.localizedDescription)"
                        login = SMAppService.mainApp.status == .enabled
                    }
                }
                if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.orange) }
                }.padding(6)
            }
            GroupBox("排除应用") {
                VStack(alignment: .leading, spacing: 8) {
                Text("每行填写一个应用 Bundle ID，例如 com.apple.Safari。")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $settings.exclusions).font(.system(.body, design: .monospaced)).frame(height: 58)
                }.padding(6)
            }
        }.padding(22).frame(width: 520, height: 570)
            .onReceive(timer) { _ in
                accessibility = AXIsProcessTrusted()
                recording = CGPreflightScreenCaptureAccess()
            }
    }
    private func permissionRow(_ title: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Label(title, systemImage: enabled ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(enabled ? Color.green : Color.secondary)
            Spacer()
            Button(enabled ? "查看设置" : "授权") {
                if enabled { openPrivacy(title == "辅助功能" ? "Privacy_Accessibility" : "Privacy_ScreenCapture") }
                else { action() }
            }
        }
    }
    private func openPrivacy(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}
