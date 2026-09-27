import AppKit
import ApplicationServices
import SwiftUI
import ServiceManagement
import PreviewCore

final class Settings: ObservableObject {
    @Published var delay: Double { didSet { UserDefaults.standard.set(delay, forKey: "hoverDelay") } }
    @Published var cardWidth: Double { didSet { UserDefaults.standard.set(cardWidth, forKey: "cardWidth") } }
    @Published var exclusions: String { didSet { UserDefaults.standard.set(exclusions, forKey: "exclusions") } }
    @Published var paused = false
    @Published var language: InterfaceLanguage {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: "interfaceLanguage")
            NotificationCenter.default.post(name: .interfaceLanguageDidChange, object: nil)
        }
    }
    init() {
        let defaults = UserDefaults.standard
        delay = defaults.object(forKey: "hoverDelay") == nil ? 0.25 : defaults.double(forKey: "hoverDelay")
        cardWidth = defaults.object(forKey: "cardWidth") == nil ? 220 : defaults.double(forKey: "cardWidth")
        exclusions = defaults.string(forKey: "exclusions") ?? ""
        language = InterfaceLanguage(rawValue: defaults.string(forKey: "interfaceLanguage") ?? "") ?? .system
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
                    Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? L10n.text("开发版"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(L10n.text("悬停 Dock 图标，选择或关闭窗口。预览仅保存在内存中。"))
                    .foregroundStyle(.secondary)
            }
            Picker(L10n.text("语言"), selection: $settings.language) {
                Text(L10n.text("跟随系统")).tag(InterfaceLanguage.system)
                Text("English").tag(InterfaceLanguage.english)
                Text("简体中文").tag(InterfaceLanguage.chinese)
            }
            .pickerStyle(.menu)
            GroupBox(L10n.text("权限")) {
                VStack(alignment: .leading, spacing: 10) {
                permissionRow(L10n.text("辅助功能"), enabled: accessibility, pane: "Privacy_Accessibility") {
                    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                    _ = AXIsProcessTrustedWithOptions(options)
                    openPrivacy("Privacy_Accessibility")
                }
                permissionRow(L10n.text("屏幕录制"), enabled: recording, pane: "Privacy_ScreenCapture") {
                    _ = CGRequestScreenCaptureAccess()
                    recording = CGPreflightScreenCaptureAccess()
                    if !recording { openPrivacy("Privacy_ScreenCapture") }
                }
                Text(L10n.text("辅助功能用于识别和操作窗口；屏幕录制用于缩略图。未授权屏幕录制时仍可使用标题列表。授权后若截图不可用，请退出并重新打开应用。"))
                    .font(.caption).foregroundStyle(.secondary)
                }.padding(6)
            }
            GroupBox(L10n.text("交互")) {
                VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(L10n.text("悬停延迟"))
                    Slider(value: $settings.delay, in: 0.15...0.8, step: 0.05)
                    Text("\(Int(settings.delay * 1000)) ms").monospacedDigit().frame(width: 65)
                }
                HStack {
                    Text(L10n.text("卡片宽度"))
                    Slider(value: $settings.cardWidth, in: 180...300, step: 20)
                    Text("\(Int(settings.cardWidth)) pt").monospacedDigit().frame(width: 65)
                }
                Toggle(L10n.text("暂停预览"), isOn: $settings.paused)
                Toggle(L10n.text("登录时启动"), isOn: $login).onChange(of: login) { _, value in
                    do {
                        if value { try SMAppService.mainApp.register() }
                        else { try SMAppService.mainApp.unregister() }
                        if SMAppService.mainApp.status == .requiresApproval {
                            message = L10n.text("请在系统设置 → 通用 → 登录项中允许启动。")
                            SMAppService.openSystemSettingsLoginItems()
                        } else { message = "" }
                    } catch {
                        message = L10n.format("登录启动设置失败：%@", error.localizedDescription)
                        login = SMAppService.mainApp.status == .enabled
                    }
                }
                if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.orange) }
                }.padding(6)
            }
            GroupBox(L10n.text("排除应用")) {
                VStack(alignment: .leading, spacing: 8) {
                Text(L10n.text("每行填写一个应用 Bundle ID，例如 com.apple.Safari。"))
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $settings.exclusions).font(.system(.body, design: .monospaced)).frame(height: 58)
                }.padding(6)
            }
        }.padding(22).frame(width: 560, height: 680)
            .onReceive(timer) { _ in
                accessibility = AXIsProcessTrusted()
                recording = CGPreflightScreenCaptureAccess()
            }
    }
    private func permissionRow(_ title: String, enabled: Bool, pane: String, action: @escaping () -> Void) -> some View {
        HStack {
            Label(title, systemImage: enabled ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(enabled ? Color.green : Color.secondary)
            Spacer()
            Button(enabled ? L10n.text("查看设置") : L10n.text("授权")) {
                if enabled { openPrivacy(pane) }
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
