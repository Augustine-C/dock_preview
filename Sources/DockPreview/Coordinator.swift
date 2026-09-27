import AppKit
import Combine
import PreviewCore
import os

@MainActor
final class PreviewCoordinator {
    let settings: Settings
    private let accessibility = AccessibilityService()
    private let capture = CaptureService()
    private let ui = PanelController()
    private let logger = Logger(subsystem: "local.augustine.DockPreview", category: "performance")
    private var hover = HoverState()
    private var target: DockTarget?
    private var records: [WindowRecord] = []
    private var monitors: [Any] = []
    private var subscriptions = Set<AnyCancellable>()
    private var observers: [NSObjectProtocol] = []
    private var probeTimer: Timer?
    private var hoverTimer: Timer?
    private var hideTimer: Timer?
    private var refreshTimer: Timer?
    private var screenshotTask: Task<Void, Never>?
    private var operationBusy = false
    private var discoveryBusy = false
    private var dockBusy = false
    private var dockRevealRetries = 0
    private var lastProbe: TimeInterval = 0
    private var lastCapture: TimeInterval = 0
    private var inputVersion: UInt64 = 0
    private var previousPoint = CGPoint.zero
    private var dismissedKey: String?
    private var screen: NSScreen? { NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } }
    init(settings: Settings) {
        self.settings = settings
        accessibility.onWindowChange = { [weak self] in Task { @MainActor in self?.discover() } }
        ui.onChoose = { [weak self] record in self?.operate(record, close: false) }
        ui.onClose = { [weak self] record in self?.operate(record, close: true) }
        ui.onDismiss = { [weak self] in self?.dismiss() }
        ui.onScroll = { [weak self] in self?.requestCapture() }
        ui.onQuit = { [weak self] in self?.quitEmptyApplication() }
        settings.$language.dropFirst().sink { [weak self] _ in self?.hide() }.store(in: &subscriptions)
        settings.$paused.dropFirst().sink { [weak self] _ in self?.hide() }.store(in: &subscriptions)
        settings.$cardWidth.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.render() }
        }.store(in: &subscriptions)
        settings.$exclusions.dropFirst().sink { [weak self] _ in self?.hide() }.store(in: &subscriptions)
    }
    func start() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .leftMouseDown, .rightMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.handle(event); return event
        }) { monitors.append(local) }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.hide() } })
        for name in [NSWorkspace.didTerminateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification,
                     NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                Task { @MainActor in
                    guard let self else { return }
                    if name == NSWorkspace.didTerminateApplicationNotification,
                       let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                        if app.processIdentifier == self.target?.app.processIdentifier || app.bundleIdentifier == "com.apple.dock" { self.hide() }
                    } else { self.hide() }
                }
            })
        }
    }
    func stop() {
        hide(); monitors.forEach(NSEvent.removeMonitor); monitors.removeAll()
        observers.forEach { NotificationCenter.default.removeObserver($0); NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll(); capture.clear()
    }
    private func handle(_ event: NSEvent) {
        let point = NSEvent.mouseLocation
        if event.type == .leftMouseDown || event.type == .rightMouseDown {
            if !ui.panel.isVisible || !ui.panel.frame.contains(point) { dismiss() }
            return
        }
        guard point != previousPoint else { return }
        previousPoint = point; inputVersion &+= 1; dockRevealRetries = 0
        guard !settings.paused, AXIsProcessTrusted() else { hide(); return }
        if insideKeepRegion(point) {
            hover.keep(); hideTimer?.invalidate(); return
        }
        guard nearDock(point) else { dismissedKey = nil; leave(); return }
        let now = ProcessInfo.processInfo.systemUptime
        guard !dockBusy else { return }
        guard now - lastProbe >= 1 / 30 else {
            probeTimer?.invalidate()
            probeTimer = oneShot(after: 1 / 30) { [weak self] in self?.probeCurrentPosition() }
            return
        }
        dockBusy = true; lastProbe = now
        let version = inputVersion
        let height = NSScreen.screens.first?.frame.height ?? 0
        accessibility.target(at: point, primaryHeight: height) { [weak self] candidate in
            guard let self else { return }
            self.dockBusy = false
            guard version == self.inputVersion else {
                // The final movement must be resolved even if it arrived during an AX query.
                self.probeCurrentPosition(); return
            }
            self.receive(candidate)
        }
    }
    private func insideKeepRegion(_ point: CGPoint) -> Bool {
        guard ui.panel.isVisible, let target else { return false }
        return ui.panel.frame.contains(point) ||
            (PanelLayout.bridge(anchor: target.anchor, panel: ui.panel.frame).contains(point) && !target.anchor.contains(point))
    }
    private func probeCurrentPosition() {
        if insideKeepRegion(NSEvent.mouseLocation) { hover.keep(); hideTimer?.invalidate(); return }
        guard !dockBusy, !settings.paused, AXIsProcessTrusted(), nearDock(NSEvent.mouseLocation) else { leave(); return }
        dockBusy = true
        let point = NSEvent.mouseLocation, version = inputVersion
        accessibility.target(at: point, primaryHeight: NSScreen.screens.first?.frame.height ?? 0) { [weak self] result in
            guard let self else { return }; self.dockBusy = false
            if version == self.inputVersion { self.receive(result) } else { self.probeCurrentPosition() }
        }
    }
    private func nearDock(_ point: CGPoint) -> Bool {
        if let target, target.anchor.insetBy(dx: -30, dy: -30).contains(point) { return true }
        return NSScreen.screens.contains { s in
            let f = s.frame
            return f.contains(point) && (point.y < f.minY + 220 || point.x < f.minX + 220 || point.x > f.maxX - 220)
        }
    }
    private func receive(_ candidate: DockTarget?) {
        guard !settings.paused, AXIsProcessTrusted() else { hide(); return }
        guard let candidate, !settings.excludes(candidate.app) else {
            dismissedKey = nil; leave()
            // Auto-hidden Dock can appear after the final mouse-move event,
            // particularly in a full-screen Space. Retry briefly, never poll idle.
            if candidate == nil, dockRevealRetries < 15, nearDock(NSEvent.mouseLocation) {
                dockRevealRetries += 1
                probeTimer?.invalidate()
                probeTimer = oneShot(after: 0.15) { [weak self] in self?.probeCurrentPosition() }
            }
            return
        }
        dockRevealRetries = 0
        guard candidate.key != dismissedKey else { return }
        dismissedKey = nil
        let now = ProcessInfo.processInfo.systemUptime
        if hover.target == candidate.key {
            target = candidate; hover.keep(); hideTimer?.invalidate()
            // Dock magnification changes the icon's anchor while the app remains the same.
            if ui.panel.isVisible { reposition() }
            else if !hover.presented && hoverTimer?.isValid != true {
                scheduleOpen(after: max(0, settings.delay - (now - hover.enteredAt)))
            }
            return
        }
        hide()
        target = candidate; hover.enter(candidate.key, at: now)
        scheduleOpen(after: settings.delay)
    }
    private func scheduleOpen(after delay: TimeInterval) {
        let token = hover.generation
        hoverTimer?.invalidate()
        hoverTimer = oneShot(after: delay) { [weak self] in
            guard let self, self.hover.accepts(token), self.hover.ready(at: ProcessInfo.processInfo.systemUptime, delay: self.settings.delay) else { return }
            self.hover.markPresented(); self.discover()
        }
    }

    private func leave() {
        guard hover.target != nil else { return }
        hover.leave(at: ProcessInfo.processInfo.systemUptime)
        hoverTimer?.invalidate()
        guard hideTimer == nil || hideTimer?.isValid == false else { return }
        hideTimer = oneShot(after: 0.2) { [weak self] in
            guard let self else { return }
            if self.hover.shouldHide(at: ProcessInfo.processInfo.systemUptime) { self.hide() }
        }
    }
    private func discover() {
        guard !discoveryBusy, let target, hover.presented, !settings.paused else { return }
        discoveryBusy = true
        let token = hover.generation, started = ProcessInfo.processInfo.systemUptime
        Task { [weak self] in
            guard let self else { return }
            let result = await self.accessibility.windows(pid: target.app.processIdentifier)
            let canQuit = result.isEmpty ? await self.accessibility.canOfferQuit(pid: target.app.processIdentifier) : false
            self.discoveryBusy = false
            guard self.hover.accepts(token) else {
                if self.hover.presented { self.discover() }; return
            }
            guard AXIsProcessTrusted() else { self.hide(); return }
            guard !result.isEmpty || canQuit else { self.hide(); return }
            let changed = result.count != self.records.count || zip(result, self.records).contains {
                $0.id != $1.id || $0.title != $1.title || $0.minimized != $1.minimized || $0.frame != $1.frame || $0.canClose != $1.canClose || $0.menuOnly != $1.menuOnly || $0.captureWindowID != $1.captureWindowID
            }
            self.records = result
            if changed || !self.ui.panel.isVisible {
                self.render()
                self.logger.info("cards_ready_ms=\((ProcessInfo.processInfo.systemUptime - started) * 1000, privacy: .public) windows=\(result.count, privacy: .public)")
            }
            self.accessibility.observe(pid: target.app.processIdentifier)
            if self.refreshTimer == nil {
                let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.discover() }
                }
                RunLoop.main.add(timer, forMode: .common); self.refreshTimer = timer
            }
            self.requestCapture()
        }
    }
    private func render() {
        guard let target, let screen, hover.presented else { return }
        ui.show(records: records, target: target, width: settings.cardWidth, screen: screen, cached: capture.cached)
    }
    private func reposition() {
        guard let target, let screen else { return }
        let frame = PanelLayout.frame(size: ui.panel.frame.size, anchor: target.anchor, screen: screen.visibleFrame, edge: target.edge)
        ui.panel.setFrame(frame, display: true)
    }
    private func requestCapture() {
        let now = ProcessInfo.processInfo.systemUptime
        guard !records.isEmpty, screenshotTask == nil, ui.panel.isVisible, now - lastCapture >= 2, CGPreflightScreenCaptureAccess() else { return }
        lastCapture = now
        let token = hover.generation, visible = ui.visibleRecords, allRecords = records
        screenshotTask = Task { [weak self] in
            guard let self else { return }
            let started = ProcessInfo.processInfo.systemUptime
            await self.capture.refresh(visible, matchingAmong: allRecords, valid: { [weak self] in
                guard let self else { return false }
                return self.hover.accepts(token) && self.ui.panel.isVisible && !Task.isCancelled
            }, update: { [weak self] id, image, status in self?.ui.update(id: id, image: image, status: status) })
            self.logger.info("capture_batch_ms=\((ProcessInfo.processInfo.systemUptime - started) * 1000, privacy: .public) windows=\(visible.count, privacy: .public)")
            self.screenshotTask = nil
            if self.hover.generation != token { self.requestCapture() }
        }
    }
    private func quitEmptyApplication() {
        guard !operationBusy, records.isEmpty, let target, ui.panel.isVisible else { return }
        operationBusy = true
        let token = hover.generation
        Task { [weak self] in
            guard let self else { return }
            defer { self.operationBusy = false }
            let error = await self.accessibility.quitApplicationIfEmpty(pid: target.app.processIdentifier)
            guard self.hover.accepts(token) else { return }
            if let error { self.ui.error(error); self.discover() }
            else { self.dismiss() }
        }
    }

    private func operate(_ record: WindowRecord, close: Bool) {
        guard !operationBusy else { return }
        operationBusy = true
        let token = hover.generation
        Task { [weak self] in
            guard let self else { return }
            defer { self.operationBusy = false }
            let error = await self.accessibility.perform(record, close: close)
            guard self.hover.accepts(token) else { return }
            if let error { self.ui.error(error) }
            else if !close { self.dismiss() }
            else {
                self.discover()
                try? await Task.sleep(for: .milliseconds(150))
                let modal = await self.accessibility.hasModalWindow(pid: record.pid)
                if modal, self.hover.accepts(token) {
                    self.dismiss()
                    NSRunningApplication(processIdentifier: record.pid)?.activate(options: [])
                }
            }
        }
    }
    func dismiss() { dismissedKey = target?.key; hide() }
    func hide() {
        hover.reset(); inputVersion &+= 1
        probeTimer?.invalidate(); hoverTimer?.invalidate(); hideTimer?.invalidate(); refreshTimer?.invalidate()
        probeTimer = nil; hoverTimer = nil; hideTimer = nil; refreshTimer = nil
        screenshotTask?.cancel() // Kept until completion so stale work cannot exceed concurrency limit.
        lastCapture = 0
        accessibility.stopObserving(); ui.hide(); target = nil; records.removeAll()
    }
    private func oneShot(after delay: TimeInterval, action: @escaping () -> Void) -> Timer {
        let timer = Timer(timeInterval: delay, repeats: false) { _ in action() }
        RunLoop.main.add(timer, forMode: .common); return timer
    }
}
