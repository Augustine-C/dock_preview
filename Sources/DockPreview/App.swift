import AppKit
import SwiftUI
import ApplicationServices
import ScreenCaptureKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    private let settings = Settings()
    private var coordinator: PreviewCoordinator?
    private var item: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var demoPanel: PanelController?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if let index = CommandLine.arguments.firstIndex(of: "--window-report"),
           CommandLine.arguments.indices.contains(index + 1) {
            let bundleID = CommandLine.arguments[index + 1]
            Task {
                guard let target = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
                    print("Target application not running: \(bundleID)"); NSApp.terminate(nil); return
                }
                let service = AccessibilityService()
                var discoveryCycle: [[String: Any]] = []
                if CommandLine.arguments.contains("--window-cycle-check"),
                   let original = NSWorkspace.shared.frontmostApplication,
                   original.processIdentifier != target.processIdentifier {
                    func describe(_ records: [WindowRecord]) -> [[String: Any]] {
                        records.map { ["axHash": CFHash($0.element), "menuOnly": $0.menuOnly] }
                    }
                    for cycle in 1...3 {
                        NSApp.activate()
                        NSApp.yieldActivation(to: target)
                        _ = target.activate(from: .current, options: [])
                        try? await Task.sleep(for: .milliseconds(800))
                        discoveryCycle.append(["cycle": cycle, "phase": "targetActive", "targetIsActive": target.isActive,
                                               "records": describe(await service.windows(pid: target.processIdentifier))])
                        NSApp.activate()
                        NSApp.yieldActivation(to: original)
                        _ = original.activate(from: .current, options: [])
                        try? await Task.sleep(for: .milliseconds(800))
                        discoveryCycle.append(["cycle": cycle, "phase": "targetInactive", "targetIsActive": target.isActive,
                                               "records": describe(await service.windows(pid: target.processIdentifier))])
                    }
                }
                var report = await service.rawWindowReport(pid: target.processIdentifier)
                if !discoveryCycle.isEmpty { report["discoveryCycle"] = discoveryCycle }
                let records = await service.windows(pid: target.processIdentifier)
                report["includedWindows"] = records.map {
                    ["axHash": CFHash($0.element), "minimized": $0.minimized, "menuOnly": $0.menuOnly,
                     "frame": [$0.frame.minX, $0.frame.minY, $0.frame.width, $0.frame.height]] as [String: Any]
                }
                if CommandLine.arguments.contains("--capture-check") {
                    let capture = CaptureService()
                    var checks: [[String: Any]] = []
                    await capture.refresh(records, matchingAmong: records, valid: { true }) { id, image, status in
                        checks.append(["id": id.uuidString, "imageAvailable": image != nil, "status": status])
                    }
                    report["captureChecks"] = checks
                }
                report["canOfferQuit"] = await service.canOfferQuit(pid: target.processIdentifier)
                report["bundleID"] = bundleID
                report["frontmostApp"] = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
                report["screenCapture"] = CGPreflightScreenCaptureAccess()
                if CGPreflightScreenCaptureAccess() {
                    do {
                        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
                        report["captureWindows"] = content.windows.filter { $0.owningApplication?.processID == target.processIdentifier }.map {
                            ["windowID": $0.windowID, "onScreen": $0.isOnScreen, "layer": $0.windowLayer,
                             "hasTitle": !($0.title ?? "").isEmpty,
                             "frame": [$0.frame.minX, $0.frame.minY, $0.frame.width, $0.frame.height]] as [String: Any]
                        }
                    } catch { report["captureError"] = error.localizedDescription }
                }
                if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                    print(String(decoding: data, as: UTF8.self))
                }
                NSApp.terminate(nil)
            }
            return
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: "Dock Preview")
        item.button?.toolTip = L10n.text("Dock Preview · 窗口预览")
        let menu = NSMenu()
        menu.addItem(withTitle: L10n.text("设置与权限…"), action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: L10n.text("暂停预览"), action: #selector(togglePause(_:)), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.text("退出 Dock Preview"), action: #selector(quit), keyEquivalent: "q").target = self
        menu.delegate = self
        item.menu = menu; self.item = item
        NotificationCenter.default.addObserver(self, selector: #selector(refreshLanguage), name: .interfaceLanguageDidChange, object: nil)
        coordinator = PreviewCoordinator(settings: settings); coordinator?.start()
        if CommandLine.arguments.contains("--settings") { openSettings() }
        else if CommandLine.arguments.contains("--demo") { showDemo() }
        else if !AXIsProcessTrusted() { openSettings() }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openSettings() }
        return true
    }
    @objc private func openSettings() {
        coordinator?.dismiss()
        if settingsWindow == nil {
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 560, height: 680),
                                  styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = L10n.text("Dock Preview 设置"); window.isReleasedWhenClosed = false; window.delegate = self
            window.contentView = NSHostingView(rootView: SettingsView(settings: settings))
            window.center(); settingsWindow = window
        }
        NSApp.activate(); settingsWindow?.makeKeyAndOrderFront(nil)
    }
    func windowWillClose(_ notification: Notification) {
        // Release SwiftUI's permission-status timer together with the closed settings page.
        settingsWindow?.contentView = nil
        settingsWindow = nil
    }
    @objc private func refreshLanguage() {
        item?.button?.toolTip = L10n.text("Dock Preview · 窗口预览")
        item?.menu?.items.first { $0.action == #selector(openSettings) }?.title = L10n.text("设置与权限…")
        item?.menu?.items.first { $0.action == #selector(togglePause(_:)) }?.title = L10n.text("暂停预览")
        item?.menu?.items.first { $0.action == #selector(quit) }?.title = L10n.text("退出 Dock Preview")
        settingsWindow?.title = L10n.text("Dock Preview 设置")
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshLanguage()
        menu.items.first { $0.action == #selector(togglePause(_:)) }?.state = settings.paused ? .on : .off
    }
    @objc private func togglePause(_ sender: NSMenuItem) {
        settings.paused.toggle(); sender.state = settings.paused ? .on : .off
    }
    @objc private func quit() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self, name: .interfaceLanguageDidChange, object: nil)
        coordinator?.stop()
    }
    private func showDemo() {
        guard let screen = NSScreen.main else { return }
        coordinator?.stop()
        let panel = PanelController()
        let pid = ProcessInfo.processInfo.processIdentifier
        let records = (1...6).map { i in
            WindowRecord(id: UUID(), pid: pid, element: AXUIElementCreateApplication(pid),
                         title: [L10n.text("项目设计 · Safari"), L10n.text("终端 — swift build"), "README.md", L10n.text("资料整理"), L10n.text("邮件"), L10n.text("已最小化的窗口")][i-1],
                         frame: CGRect(x: 0, y: 0, width: 1000, height: 700), minimized: i == 6, canClose: true)
        }
        let target = DockTarget(app: NSRunningApplication.current,
                                anchor: CGRect(x: screen.frame.midX - 25, y: screen.visibleFrame.minY, width: 50, height: 50), edge: .bottom)
        panel.onChoose = { _ in panel.error(L10n.text("演示模式：不会操作真实窗口")) }
        panel.onClose = { _ in panel.error(L10n.text("演示模式：不会关闭真实窗口")) }
        panel.onDismiss = { panel.hide() }
        panel.show(records: records, target: target, width: 220, screen: screen, cached: { _ in nil })
        demoPanel = panel
    }
}

@main
struct DockPreviewApp {
    @MainActor static func main() {
if CommandLine.arguments.contains("--diagnose") {
    let information: [String: Any] = [
        "os": ProcessInfo.processInfo.operatingSystemVersionString,
        "accessibility": AXIsProcessTrusted(),
        "screenCapture": CGPreflightScreenCaptureAccess(),
        "architecture": "arm64",
        "minimumOS": "27.0",
        "settingsTitle": L10n.text("Dock Preview 设置"),
        "quitLabel": L10n.text("退出应用")
    ]
    if let data = try? JSONSerialization.data(withJSONObject: information, options: [.prettyPrinted, .sortedKeys]) {
        print(String(decoding: data, as: UTF8.self))
    }
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
    }
}
