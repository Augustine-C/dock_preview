import AppKit
import ApplicationServices
import PreviewCore
import os

struct DockTarget {
    let app: NSRunningApplication
    let anchor: CGRect // AppKit screen coordinates
    let edge: DockEdge
    var key: String { "\(app.processIdentifier)" }
}
struct WindowRecord: Identifiable {
    let id: UUID
    let pid: pid_t
    let element: AXUIElement
    let title: String
    let frame: CGRect // Accessibility/ScreenCaptureKit coordinates
    let minimized: Bool
    let canClose: Bool
    var menuOnly = false
    var captureWindowID: CGWindowID? = nil
    var descriptor: WindowDescriptor { .init(pid: pid, title: title, frame: frame) }
}

private func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value as? T
}
private func axFrame(_ element: AXUIElement) -> CGRect? {
    guard let p: AXValue = attribute(element, kAXPositionAttribute),
          let s: AXValue = attribute(element, kAXSizeAttribute) else { return nil }
    var point = CGPoint.zero, size = CGSize.zero
    guard AXValueGetValue(p, .cgPoint, &point), AXValueGetValue(s, .cgSize, &size) else { return nil }
    return CGRect(origin: point, size: size)
}
func appKitRect(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
    CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
}

// AX and identity state are confined to queue. Observer installation/lifecycle and
// onWindowChange are confined to the main thread; hand-offs retain their payloads.
final class AccessibilityService: @unchecked Sendable {
    private let queue = DispatchQueue(label: "local.DockPreview.accessibility", qos: .userInitiated)
    private var identities: [pid_t: [(AXUIElement, UUID)]] = [:]
    private var knownRecords: [pid_t: [WindowRecord]] = [:]
    private var menuAssociations: [pid_t: [(AXUIElement, WindowMenuAssociation)]] = [:]
    private let logger = Logger(subsystem: "local.augustine.DockPreview", category: "interaction")
    private var lastDockLog: TimeInterval = 0
    private var lastDockFallback: TimeInterval = 0
    private var dockPID: pid_t = 0
    private var dock: AXUIElement?
    private var observer: AXObserver?
    private var observedPID: pid_t = 0
    private var observerGeneration: UInt64 = 0
    var onWindowChange: (() -> Void)?

    func target(at point: CGPoint, primaryHeight: CGFloat, completion: @escaping (DockTarget?) -> Void) {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
        queue.async { [self] in
            guard let app = apps.first else { DispatchQueue.main.async { completion(nil) }; return }
            if dockPID != app.processIdentifier {
                dockPID = app.processIdentifier
                dock = AXUIElementCreateApplication(dockPID)
                AXUIElementSetMessagingTimeout(dock!, 0.15)
            }
            guard let dock else { return }
            var hit: AXUIElement?
            let status = AXUIElementCopyElementAtPosition(dock, Float(point.x), Float(primaryHeight - point.y), &hit)
            var result: DockTarget?
            if status == .success, var element = hit {
                for _ in 0..<6 {
                    let role: String? = attribute(element, kAXRoleAttribute)
                    let subrole: String? = attribute(element, kAXSubroleAttribute)
                    if role == "AXDockItem", subrole == "AXApplicationDockItem",
                       let url: URL = attribute(element, kAXURLAttribute),
                       let frame = axFrame(element),
                       let running = NSWorkspace.shared.runningApplications.first(where: {
                           $0.bundleURL?.standardizedFileURL == url.standardizedFileURL && !$0.isTerminated
                       }), running.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                        let anchor = appKitRect(frame, primaryHeight: primaryHeight)
                        let orientation = UserDefaults(suiteName: "com.apple.dock")?.string(forKey: "orientation") ?? "bottom"
                        let edge: DockEdge = orientation == "left" ? .left : orientation == "right" ? .right : .bottom
                        result = DockTarget(app: running, anchor: anchor, edge: edge)
                        break
                    }
                    guard let parent: AXUIElement = attribute(element, kAXParentAttribute) else { break }
                    element = parent
                }
            }
            let now = ProcessInfo.processInfo.systemUptime
            var fallback = false
            if result == nil, now - lastDockFallback >= 0.2 {
                lastDockFallback = now
                // Hit-testing can return AXNoValue while Dock reveals in a
                // full-screen Space. Read the Dock's own exposed item bounds;
                // never infer application identity from icon order or pixels.
                let axPoint = CGPoint(x: point.x, y: primaryHeight - point.y)
                var pending: [(AXUIElement, Int)] = [(dock, 0)]
                var visited = 0
                while let (node, depth) = pending.popLast(), visited < 256, result == nil {
                    visited += 1
                    let role: String? = attribute(node, kAXRoleAttribute)
                    if role == "AXDockItem" {
                        guard let frame = axFrame(node), frame.contains(axPoint),
                              (attribute(node, kAXSubroleAttribute) as String?) == "AXApplicationDockItem",
                              let url: URL = attribute(node, kAXURLAttribute),
                              let running = NSWorkspace.shared.runningApplications.first(where: {
                                  $0.bundleURL?.standardizedFileURL == url.standardizedFileURL && !$0.isTerminated
                              }), running.processIdentifier != ProcessInfo.processInfo.processIdentifier else { continue }
                        let orientation = UserDefaults(suiteName: "com.apple.dock")?.string(forKey: "orientation") ?? "bottom"
                        let edge: DockEdge = orientation == "left" ? .left : orientation == "right" ? .right : .bottom
                        result = DockTarget(app: running, anchor: appKitRect(frame, primaryHeight: primaryHeight), edge: edge)
                        fallback = true
                    } else if depth < 3 {
                        if depth > 0, let frame = axFrame(node), !frame.contains(axPoint) { continue }
                        let children: [AXUIElement] = attribute(node, kAXChildrenAttribute) ?? []
                        pending.append(contentsOf: children.prefix(128).map { ($0, depth + 1) })
                    }
                }
            }
            if now - lastDockLog > 1 {
                lastDockLog = now
                logger.info("dock_probe ax=\(status.rawValue) target=\(result?.app.processIdentifier ?? 0) fallback=\(fallback)")
            }
            let resolved = result
            DispatchQueue.main.async { completion(resolved) }
        }
    }

    func windows(pid: pid_t) async -> [WindowRecord] {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                let app = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(app, 0.2)
                var elements: [AXUIElement] = attribute(app, kAXWindowsAttribute) ?? []
                let children: [AXUIElement] = attribute(app, kAXChildrenAttribute) ?? []
                for child in children where (attribute(child, kAXRoleAttribute) as String?) == kAXWindowRole as String {
                    if !elements.contains(where: { CFEqual($0, child) }) { elements.append(child) }
                }
                // AXWindows/children can omit the main window on another Space,
                // even though the application still exposes the exact object.
                let mainWindow: AXUIElement? = attribute(app, kAXMainWindowAttribute)
                if let mainWindow, !elements.contains(where: { CFEqual($0, mainWindow) }) {
                    elements.append(mainWindow)
                }
                let old = identities[pid] ?? []
                // AXWindows is a snapshot, not a destruction signal. Some apps omit
                // minimized/off-Space windows. Revalidate retained AX references.
                for (element, _) in old where !elements.contains(where: { CFEqual($0, element) }) {
                    var role: CFTypeRef?
                    let error = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
                    if error == .success && role as? String == kAXWindowRole as String || error == .cannotComplete {
                        elements.append(element)
                    }
                }
                var fresh: [(AXUIElement, UUID)] = []
                var records = elements.compactMap { element -> WindowRecord? in
                    let role: String? = attribute(element, kAXRoleAttribute)
                    let subrole: String? = attribute(element, kAXSubroleAttribute)
                    let previous = knownRecords[pid]?.first { CFEqual($0.element, element) }
                    let minimized: Bool = attribute(element, kAXMinimizedAttribute) ?? previous?.minimized ?? false
                    let frame = axFrame(element)
                    var settable = DarwinBoolean(false)
                    if subrole == "AXUnknown" || subrole == "AXDialog" { _ = AXUIElementIsAttributeSettable(element, kAXMinimizedAttribute as CFString, &settable) }
                    if role == nil, let previous {
                        // Only an explicit invalid-element result proves destruction.
                        var value: CFTypeRef?
                        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .cannotComplete {
                            fresh.append((element, previous.id)); return previous
                        }
                    }
                    guard WindowEligibility.includes(role: role, subrole: subrole, minimized: minimized, frame: frame,
                                                     minimizable: settable.boolValue) else { return nil }
                    let id = previous?.id ?? old.first { CFEqual($0.0, element) }?.1 ?? UUID()
                    fresh.append((element, id))
                    let title: String = attribute(element, kAXTitleAttribute) ?? previous?.title ?? L10n.text("未命名窗口")
                    let close: AXUIElement? = attribute(element, kAXCloseButtonAttribute)
                    let enabled: Bool = close.flatMap { attribute($0, kAXEnabledAttribute) } ?? false
                    return WindowRecord(id: id, pid: pid, element: element,
                                        title: title.isEmpty ? L10n.text("未命名窗口") : title, frame: frame ?? .zero,
                                        minimized: minimized,
                                        canClose: close != nil && enabled)
                }
                // Window-menu entries remain exposed when AXWindows omits other
                // Spaces. Operate on the exact menu element, never a title-guessed window.
                let menuEntries = windowMenuEntries(app)
                let descriptors = records.map(\.descriptor)
                let mainRecord = mainWindow.flatMap { main in records.first { !$0.menuOnly && CFEqual($0.element, main) } }
                let knownWindowIDs = Set(records.map(\.id))
                let oldAssociations = menuAssociations[pid] ?? []
                // A missing menu snapshot is not an identity change. Keep links
                // for still-known windows until an entry is replaced or retitled.
                var freshAssociations = oldAssociations.filter { knownWindowIDs.contains($0.1.windowID) }
                for entry in menuEntries {
                    guard let title: String = attribute(entry, kAXTitleAttribute), !title.isEmpty else { continue }
                    let mark: String = attribute(entry, kAXMenuItemMarkCharAttribute) ?? ""
                    // Confirm the association while AppKit marks its main window,
                    // then retain it across inactive/off-Space snapshots. Menu object,
                    // title and live window identity must all still agree.
                    let association: WindowMenuAssociation?
                    if let confirmedID = WindowMenuAssociation.confirmedWindowID(selected: mark == "✓",
                        menuWindowCount: menuEntries.count, windowIDs: records.map(\.id), mainWindowID: mainRecord?.id) {
                        association = WindowMenuAssociation(title: title, windowID: confirmedID)
                    } else {
                        association = oldAssociations.first {
                            CFEqual($0.0, entry) && $0.1.represents(title: title, knownWindowIDs: knownWindowIDs)
                        }?.1
                    }
                    freshAssociations.removeAll { CFEqual($0.0, entry) }
                    if let association { freshAssociations.append((entry, association)) }
                    guard WindowMatcher.needsMenuFallback(title: title, windows: descriptors,
                                                          selectedWindowIsKnown: association != nil) else { continue }
                    let id = old.first { CFEqual($0.0, entry) }?.1 ?? UUID()
                    records.append(WindowRecord(id: id, pid: pid, element: entry, title: title,
                                                frame: .zero, minimized: mark == "◆", canClose: false, menuOnly: true))
                    fresh.append((entry, id))
                }
                if records.isEmpty, CGPreflightScreenCaptureAccess(),
                   let info = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
                    // Some applications (including System Settings) expose no AX
                    // windows or Window menu outside their Space. Use explicit CG
                    // IDs for previews, never invent an AX window operation target.
                    for entry in info {
                        guard (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                              (entry[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                              let title = entry[kCGWindowName as String] as? String, !title.isEmpty,
                              let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
                              let frame = CGRect(dictionaryRepresentation: bounds), frame.width > 40, frame.height > 40,
                              let number = entry[kCGWindowNumber as String] as? NSNumber else { continue }
                        let windowID = number.uint32Value
                        let id = knownRecords[pid]?.first { $0.captureWindowID == windowID }?.id ?? UUID()
                        records.append(WindowRecord(id: id, pid: pid, element: app, title: title, frame: frame,
                                                    minimized: false, canClose: false, captureWindowID: windowID))
                    }
                }
                menuAssociations[pid] = Array(freshAssociations.prefix(256))
                identities[pid] = Array(fresh.prefix(256))
                knownRecords[pid] = Array(records.prefix(256))
                if identities.count > 8 {
                    identities.keys.filter { $0 != pid }.prefix(identities.count - 8).forEach { identities.removeValue(forKey: $0); knownRecords.removeValue(forKey: $0); menuAssociations.removeValue(forKey: $0) }
                }
                continuation.resume(returning: Array(records.prefix(256)))
            }
        }
    }

    /// An empty filtered preview is not proof that an app has no windows.
    /// Require a successful AX query and no window objects/menu items/CG windows.
    func canOfferQuit(pid: pid_t) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                let app = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(app, 0.2)
                var value: CFTypeRef?
                guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
                      let windows = value as? [AXUIElement],
                      !windows.contains(where: { (attribute($0, kAXRoleAttribute) as String?) == "AXWindow" }),
                      windowMenuEntries(app).isEmpty,
                      let info = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
                    continuation.resume(returning: false); return
                }
                let hasWindow = info.contains { entry in
                    guard (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                          (entry[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                          let bounds = entry[kCGWindowBounds as String] as? [String: Any] else { return false }
                    let width = (bounds["Width"] as? NSNumber)?.doubleValue ?? 0
                    let height = (bounds["Height"] as? NSNumber)?.doubleValue ?? 0
                    guard width > 40, height > 40 else { return false }
                    let visible = (entry[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
                    let title = (entry[kCGWindowName as String] as? String) ?? ""
                    // AppKit/WebKit can retain ordered-out internal windows with
                    // large bounds. Bounds alone do not establish a user window.
                    // Named off-Space windows still prevent the empty state.
                    return visible || !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !CGPreflightScreenCaptureAccess()
                }
                continuation.resume(returning: !hasWindow)
            }
        }
    }

    func quitApplicationIfEmpty(pid: pid_t) async -> String? {
        guard await canOfferQuit(pid: pid) else { return L10n.text("应用已有窗口，或暂时无法确认窗口状态") }
        guard await activateTarget(pid: pid) else { return L10n.text("无法激活应用，请重试") }
        guard await canOfferQuit(pid: pid) else { return L10n.text("应用已有窗口，退出操作已取消") }
        return await MainActor.run {
            guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return nil }
            return app.terminate() ? nil : L10n.text("应用未接受退出请求")
        }
    }

    private func windowMenuEntries(_ app: AXUIElement) -> [AXUIElement] {
        guard let bar: AXUIElement = attribute(app, kAXMenuBarAttribute) else { return [] }
        let items: [AXUIElement] = attribute(bar, kAXChildrenAttribute) ?? []
        var result: [AXUIElement] = []
        for item in items {
            let menus: [AXUIElement] = attribute(item, kAXChildrenAttribute) ?? []
            for menu in menus {
                let entries: [AXUIElement] = attribute(menu, kAXChildrenAttribute) ?? []
                result.append(contentsOf: entries.filter {
                    (attribute($0, kAXIdentifierAttribute) as String?) == "makeKeyAndOrderFront:"
                })
            }
        }
        return Array(result.prefix(256))
    }

    @MainActor
    private func activateTarget(pid: pid_t) async -> Bool {
        guard let target = NSRunningApplication(processIdentifier: pid), !target.isTerminated else { return false }
        if target.isActive { return true }
        // A nonactivating preview panel owns keyboard focus without owning app
        // activation. Claim activation only after a deliberate card click, then
        // hand it to the target through AppKit's cooperative activation API.
        NSApp.activate()
        for _ in 0..<15 where !NSApp.isActive {
            try? await Task.sleep(for: .milliseconds(20))
        }
        _ = target.unhide()
        NSApp.yieldActivation(to: target)
        let accepted = target.activate(from: .current, options: [])
        for _ in 0..<25 where !target.isActive {
            try? await Task.sleep(for: .milliseconds(20))
        }
        logger.info("activate pid=\(pid) accepted=\(accepted) active=\(target.isActive)")
        return target.isActive
    }

    func perform(_ window: WindowRecord, close: Bool) async -> String? {
        if !close, !(await activateTarget(pid: window.pid)) {
            return L10n.text("系统未允许切换到目标应用，请重试")
        }
        return await withCheckedContinuation { continuation in
            queue.async { [self] in
                AXUIElementSetMessagingTimeout(window.element, 0.25)
                if window.captureWindowID != nil {
                    guard !close else { continuation.resume(returning: L10n.text("无法安全关闭此窗口")); return }
                    let app = AXUIElementCreateApplication(window.pid)
                    let elements: [AXUIElement] = attribute(app, kAXWindowsAttribute) ?? []
                    let actual = elements.compactMap { element -> WindowRecord? in
                        guard (attribute(element, kAXRoleAttribute) as String?) == "AXWindow", let frame = axFrame(element) else { return nil }
                        return WindowRecord(id: window.id, pid: window.pid, element: element,
                                            title: attribute(element, kAXTitleAttribute) ?? "", frame: frame,
                                            minimized: attribute(element, kAXMinimizedAttribute) ?? false, canClose: false)
                    }
                    if let index = WindowMatcher.uniqueMatch(window.descriptor, candidates: actual.map(\.descriptor)) {
                        let target = actual[index]
                        if target.minimized {
                            let error = AXUIElementSetAttributeValue(target.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                            guard error == .success else { continuation.resume(returning: operationError(error)); return }
                        }
                        finishRestore(target, attemptsRemaining: 10, continuation: continuation)
                    } else if knownRecords[window.pid]?.count == 1 {
                        finishCaptureActivation(window, attemptsRemaining: 15, continuation: continuation)
                    } else {
                        continuation.resume(returning: L10n.text("应用已激活，但无法安全选择该窗口"))
                    }
                    return
                }
                if window.menuOnly {
                    guard !close,
                          (attribute(window.element, kAXIdentifierAttribute) as String?) == "makeKeyAndOrderFront:",
                          (attribute(window.element, kAXTitleAttribute) as String?) == window.title else {
                        continuation.resume(returning: L10n.text("窗口列表已变化，请重新打开预览")); return
                    }
                    let error = AXUIElementPerformAction(window.element, kAXPressAction as CFString)
                    logger.info("menu_select pid=\(window.pid) ax=\(error.rawValue)")
                    continuation.resume(returning: operationError(error)); return
                }
                if close {
                    let error: AXError
                    if let button: AXUIElement = attribute(window.element, kAXCloseButtonAttribute) {
                        error = AXUIElementPerformAction(button, kAXPressAction as CFString)
                    } else { error = .actionUnsupported }
                    continuation.resume(returning: operationError(error))
                    return
                }
                let currentlyMinimized: Bool = attribute(window.element, kAXMinimizedAttribute) ?? window.minimized
                if currentlyMinimized {
                    let error = AXUIElementSetAttributeValue(window.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                    guard error == .success else {
                        continuation.resume(returning: operationError(error)); return
                    }
                }
                finishRestore(window, attemptsRemaining: 10, continuation: continuation)
            }
        }
    }

    private func finishCaptureActivation(_ window: WindowRecord, attemptsRemaining: Int,
                                         continuation: CheckedContinuation<String?, Never>) {
        let visible = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        if visible.contains(where: {
            ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == window.pid &&
            ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == window.captureWindowID
        }) {
            continuation.resume(returning: nil); return
        }
        guard attemptsRemaining > 0 else {
            continuation.resume(returning: L10n.text("应用已激活，系统尚未切换到窗口所在桌面")); return
        }
        queue.asyncAfter(deadline: .now() + 0.1) { [self] in
            finishCaptureActivation(window, attemptsRemaining: attemptsRemaining - 1, continuation: continuation)
        }
    }

    private func finishRestore(_ window: WindowRecord, attemptsRemaining: Int,
                               continuation: CheckedContinuation<String?, Never>) {
        let minimized: Bool = attribute(window.element, kAXMinimizedAttribute) ?? false
        if minimized {
            guard attemptsRemaining > 0 else {
                continuation.resume(returning: L10n.text("窗口暂未恢复，请重试或在应用中恢复")); return
            }
            // Restoration can be asynchronous. Do not raise a still-miniaturized
            // window, and do not block the AX queue while waiting for its transition.
            queue.asyncAfter(deadline: .now() + 0.05) { [self] in
                finishRestore(window, attemptsRemaining: attemptsRemaining - 1, continuation: continuation)
            }
            return
        }
        // A unique Window-menu entry requests the system's own Space switch.
        // AXRaise alone may focus an off-Space object without changing Spaces.
        let menuMatches = windowMenuEntries(AXUIElementCreateApplication(window.pid)).filter {
            (attribute($0, kAXTitleAttribute) as String?) == window.title
        }
        let knownMatches = knownRecords[window.pid]?.filter { $0.title == window.title } ?? []
        if menuMatches.count == 1, knownMatches.count == 1 {
            let menuError = AXUIElementPerformAction(menuMatches[0], kAXPressAction as CFString)
            logger.info("window_menu_select pid=\(window.pid) ax=\(menuError.rawValue)")
        }
        var error = AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
        let app = AXUIElementCreateApplication(window.pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(app, kAXFocusedWindowAttribute as CFString, &settable) == .success, settable.boolValue {
            let focusError = AXUIElementSetAttributeValue(app, kAXFocusedWindowAttribute as CFString, window.element)
            if focusError == .success { error = .success }
        }
        logger.info("window_select pid=\(window.pid) ax=\(error.rawValue)")
        continuation.resume(returning: operationError(error))
    }

    private func operationError(_ error: AXError) -> String? {
        error == .success ? nil : L10n.format("操作未完成，请在应用中操作（%d）", error.rawValue)
    }

    /// Read-only diagnostics from the app's own authorized identity. No screenshots,
    /// window activation, or private window titles are included.
    func rawWindowReport(pid: pid_t) async -> [String: Any] {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                let app = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(app, 0.5)
                var windowsValue: CFTypeRef?
                let windowsError = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsValue)
                let windows = windowsValue as? [AXUIElement] ?? []
                var count: CFIndex = 0
                let countError = AXUIElementGetAttributeValueCount(app, kAXWindowsAttribute as CFString, &count)
                var copied: CFArray?
                let arrayError = AXUIElementCopyAttributeValues(app, kAXWindowsAttribute as CFString, 0, max(1, count), &copied)
                let arrayWindows = copied as? [AXUIElement] ?? []
                let children: [AXUIElement] = attribute(app, kAXChildrenAttribute) ?? []
                let childWindows = children.filter { (attribute($0, kAXRoleAttribute) as String?) == "AXWindow" }
                func description(_ element: AXUIElement) -> [String: Any] {
                    let title: String = attribute(element, kAXTitleAttribute) ?? ""
                    var result: [String: Any] = ["axHash": CFHash(element),
                        "titleFormatChanged": WindowMatcher.normalizedTitle(title) != title, "titleEmpty": title.isEmpty]
                    for name in [kAXRoleAttribute, kAXSubroleAttribute, kAXMinimizedAttribute] {
                        var value: CFTypeRef?
                        let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
                        result[name] = ["error": error.rawValue,
                                        "value": value.map { String(describing: $0) } ?? "unavailable",
                                        "typeID": value.map { CFGetTypeID($0) } ?? 0]
                    }
                    if let frame = axFrame(element) {
                        result["frame"] = [frame.minX, frame.minY, frame.width, frame.height]
                    } else { result["frame"] = "unavailable" }
                    return result
                }
                var menuWindows: [[String: Any]] = []
                if let menuBar: AXUIElement = attribute(app, kAXMenuBarAttribute) {
                    let items: [AXUIElement] = attribute(menuBar, kAXChildrenAttribute) ?? []
                    for item in items {
                        let menus: [AXUIElement] = attribute(item, kAXChildrenAttribute) ?? []
                        for menu in menus {
                            let entries: [AXUIElement] = attribute(menu, kAXChildrenAttribute) ?? []
                            for entry in entries {
                                let identifier: String = attribute(entry, kAXIdentifierAttribute) ?? ""
                                if identifier == "makeKeyAndOrderFront:" {
                                    let title: String = attribute(entry, kAXTitleAttribute) ?? ""
                                    let normalizedMatches = windows.indices.filter {
                                        WindowMatcher.normalizedTitle(attribute(windows[$0], kAXTitleAttribute) as String? ?? "") == WindowMatcher.normalizedTitle(title)
                                    }
                                    let rawMatches = windows.indices.filter {
                                        (attribute(windows[$0], kAXTitleAttribute) as String?) == title
                                    }
                                    let linked: [AXUIElement] = attribute(entry, kAXLinkedUIElementsAttribute) ?? []
                                    menuWindows.append(["axHash": CFHash(entry), "identifier": identifier,
                                                        "mark": attribute(entry, kAXMenuItemMarkCharAttribute) as String? ?? "",
                                                        "linked": linked.map(description),
                                                        "rawWindowMatches": rawMatches, "normalizedWindowMatches": normalizedMatches])
                                }
                            }
                        }
                    }
                }
                let retained = identities[pid]?.map { description($0.0) } ?? []
                continuation.resume(returning: ["pid": pid, "trusted": AXIsProcessTrusted(),
                    "windowsError": windowsError.rawValue, "countError": countError.rawValue,
                    "reportedCount": count, "arrayError": arrayError.rawValue,
                    "windows": windows.map(description), "arrayWindows": arrayWindows.map(description),
                    "childWindows": childWindows.map(description), "retainedWindows": retained,
                    "windowMenuItems": menuWindows,
                    "mainWindow": (attribute(app, kAXMainWindowAttribute) as AXUIElement?).map(description) ?? [:]])
            }
        }
    }

    func hasModalWindow(pid: pid_t) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async {
                let app = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(app, 0.15)
                let windows: [AXUIElement] = attribute(app, kAXWindowsAttribute) ?? []
                let modal = windows.contains { window in
                    let children: [AXUIElement] = attribute(window, kAXChildrenAttribute) ?? []
                    let hasSheet = children.contains { (attribute($0, kAXRoleAttribute) as String?) == kAXSheetRole as String }
                    let isModal: Bool = attribute(window, kAXModalAttribute) ?? false
                    let subrole: String = attribute(window, kAXSubroleAttribute) ?? ""
                    return hasSheet || isModal || subrole == kAXDialogSubrole as String
                }
                continuation.resume(returning: modal)
            }
        }
    }

    func observe(pid: pid_t) {
        guard observedPID != pid else { return }
        stopObserving()
        observedPID = pid
        let generation = observerGeneration
        queue.async { [self] in
            let callback: AXObserverCallback = { _, element, notification, context in
                guard let context else { return }
                let service = Unmanaged<AccessibilityService>.fromOpaque(context).takeUnretainedValue()
                if notification as String == kAXUIElementDestroyedNotification {
                    service.queue.async {
                        for pid in Array(service.identities.keys) {
                            service.identities[pid]?.removeAll { CFEqual($0.0, element) }
                            service.knownRecords[pid]?.removeAll { CFEqual($0.element, element) }
                        }
                    }
                }
                DispatchQueue.main.async { service.onWindowChange?() }
            }
            var created: AXObserver?
            guard AXObserverCreate(pid, callback, &created) == .success, let created else { return }
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.15)
            let context = Unmanaged.passUnretained(self).toOpaque()
            for notification in [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification] {
                AXObserverAddNotification(created, app, notification as CFString, context)
            }
            let windows: [AXUIElement] = attribute(app, kAXWindowsAttribute) ?? []
            for window in windows {
                for notification in [kAXUIElementDestroyedNotification, kAXTitleChangedNotification,
                                     kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification] {
                    AXObserverAddNotification(created, window, notification as CFString, context)
                }
            }
            DispatchQueue.main.async { [self] in
                guard observedPID == pid, observerGeneration == generation, observer == nil else { return }
                observer = created
                CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
            }
        }
    }

    func stopObserving() {
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        observer = nil; observedPID = 0; observerGeneration &+= 1
    }
}
