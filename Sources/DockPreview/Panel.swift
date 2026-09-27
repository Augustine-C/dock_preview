import AppKit
import PreviewCore
import os

final class PreviewPanel: NSPanel {
    var onKey: ((UInt16) -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown { makeKey() }
        super.sendEvent(event)
    }
    override func keyDown(with event: NSEvent) {
        if [123, 124, 125, 126, 36, 76, 53].contains(event.keyCode) { onKey?(event.keyCode) }
        else { super.keyDown(with: event) }
    }
}
private final class FlippedView: NSView { override var isFlipped: Bool { true } }

final class WindowCard: NSView {
    let record: WindowRecord
    private let picture = NSImageView()
    private let placeholder = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let close = NSButton()
    private var hovered = false
    var selected = false { didSet { style() } }
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    init(record: WindowRecord, icon: NSImage?, frame: CGRect) {
        self.record = record
        super.init(frame: frame)
        wantsLayer = true; layer?.cornerRadius = 10
        picture.frame = CGRect(x: 8, y: 42, width: frame.width - 16, height: frame.height - 50)
        picture.imageScaling = .scaleProportionallyUpOrDown
        picture.isHidden = true
        placeholder.frame = CGRect(x: (frame.width - 48) / 2, y: 42 + (frame.height - 50 - 48) / 2, width: 48, height: 48)
        placeholder.imageScaling = .scaleProportionallyUpOrDown
        placeholder.image = icon ?? NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)
        title.stringValue = record.title
        title.font = .systemFont(ofSize: 12, weight: .medium)
        title.lineBreakMode = .byTruncatingMiddle
        title.frame = CGRect(x: 10, y: 23, width: frame.width - 20, height: 16)
        detail.font = .systemFont(ofSize: 10); detail.textColor = .secondaryLabelColor
        detail.frame = CGRect(x: 10, y: 7, width: frame.width - 20, height: 14)
        detail.stringValue = record.minimized ? "已最小化 · 标题预览" : (record.menuOnly ? "其他桌面 · 点击切换" : "标题预览")
        close.frame = CGRect(x: frame.width - 29, y: frame.height - 29, width: 23, height: 23)
        close.bezelStyle = .circular; close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "关闭窗口")
        close.target = self; close.action = #selector(closePressed)
        close.isEnabled = record.canClose
        close.toolTip = record.canClose ? "关闭此窗口" : "此窗口不支持关闭"
        addSubview(picture); addSubview(placeholder); addSubview(title); addSubview(detail); addSubview(close)
        setAccessibilityElement(true); setAccessibilityRole(.button)
        setAccessibilityLabel(record.title + (record.minimized ? "，已最小化" : ""))
        toolTip = record.title
        style()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        // The full card, including its image and labels, is one selection target.
        // Only the close button consumes clicks separately.
        if hit === close || hit.isDescendant(of: close) { return hit }
        return self
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; style() }
    override func mouseExited(with event: NSEvent) { hovered = false; style() }
    override func mouseDown(with event: NSEvent) { window?.makeKey(); onSelect?() }
    override func accessibilityPerformPress() -> Bool { onSelect?(); return true }
    @objc private func closePressed() { onClose?() }
    func update(image: NSImage?, status: String) {
        if let image { picture.image = image; picture.isHidden = false; placeholder.isHidden = true }
        // Capture progress is internal state: keep the caption stable while a
        // usable image is displayed, including when a refresh falls back to cache.
        let caption = picture.image != nil ? "窗口预览" : status
        let parts = [record.minimized ? "已最小化" : "", caption].filter { !$0.isEmpty }
        let text = parts.joined(separator: " · ")
        if detail.stringValue != text { detail.stringValue = text }
    }
    private func style() {
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(hovered || selected ? 0.85 : 0.4).cgColor
        layer?.borderWidth = selected ? 2 : 0
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        close.isHidden = !(hovered || selected)
    }
}

final class PanelController {
    let panel: PreviewPanel
    private let scroll = NSScrollView()
    private let document = FlippedView()
    private let heading = NSTextField(labelWithString: "")
    private let footer = NSTextField(labelWithString: "")
    private(set) var cards: [WindowCard] = []
    private var selectedIndex = 0
    private var columns = 1
    var onChoose: ((WindowRecord) -> Void)?
    var onClose: ((WindowRecord) -> Void)?
    var onDismiss: (() -> Void)?
    var onScroll: (() -> Void)?
    init() {
        panel = PreviewPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        let effect = NSVisualEffectView()
        effect.material = .popover; effect.blendingMode = .behindWindow; effect.state = .active
        effect.wantsLayer = true; effect.layer?.cornerRadius = 14; effect.layer?.masksToBounds = true
        panel.contentView = effect
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        footer.font = .systemFont(ofSize: 10); footer.textColor = .secondaryLabelColor
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.documentView = document
        effect.addSubview(heading); effect.addSubview(scroll); effect.addSubview(footer)
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in self?.onScroll?() }
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: panel, queue: .main) { [weak self] _ in self?.applySelection() }
        panel.onKey = { [weak self] code in self?.key(code) }
    }
    func show(records: [WindowRecord], target: DockTarget, width: CGFloat, screen: NSScreen,
              cached: (WindowRecord) -> NSImage?) {
        let previouslySelected = cards.indices.contains(selectedIndex) ? cards[selectedIndex].record.id : nil
        let oldOrigin = scroll.contentView.bounds.origin
        cards.forEach { $0.removeFromSuperview() }; cards.removeAll()
        columns = PanelLayout.columns(count: records.count, screenWidth: screen.visibleFrame.width, cardWidth: width)
        let cardWidth = min(width, max(80, screen.visibleFrame.width - 48))
        let cardHeight = cardWidth * 0.625 + 42
        let rows = Int(ceil(Double(records.count) / Double(columns)))
        let contentHeight = CGFloat(rows) * (cardHeight + 10) - 10
        let panelWidth = CGFloat(columns) * (cardWidth + 10) + 14
        let viewHeight = min(contentHeight, max(80, screen.visibleFrame.height - 140))
        let panelHeight = viewHeight + 68
        let frame = PanelLayout.frame(size: CGSize(width: panelWidth, height: panelHeight), anchor: target.anchor,
                                      screen: screen.visibleFrame, edge: target.edge)
        panel.setFrame(frame, display: false)
        heading.stringValue = "\(target.app.localizedName ?? "应用") · \(records.count) 个窗口"
        heading.frame = CGRect(x: 14, y: frame.height - 30, width: frame.width - 28, height: 18)
        footer.stringValue = "点击切换 · × 关闭 · 点击后可用方向键 / Enter / Esc"
        footer.frame = CGRect(x: 14, y: 9, width: frame.width - 28, height: 14)
        scroll.frame = CGRect(x: 12, y: 30, width: frame.width - 24, height: viewHeight)
        document.frame = CGRect(x: 0, y: 0, width: frame.width - 24, height: contentHeight)
        for (index, record) in records.enumerated() {
            let card = WindowCard(record: record, icon: target.app.icon,
                frame: CGRect(x: CGFloat(index % columns) * (cardWidth + 10),
                              y: CGFloat(index / columns) * (cardHeight + 10), width: cardWidth, height: cardHeight))
            card.onSelect = { [weak self] in self?.onChoose?(record) }
            card.onClose = { [weak self] in self?.onClose?(record) }
            if let image = cached(record) { card.update(image: image, status: "缓存预览") }
            document.addSubview(card); cards.append(card)
        }
        selectedIndex = previouslySelected.flatMap { id in cards.firstIndex { $0.record.id == id } } ?? 0
        if panel.isKeyWindow { applySelection() }
        scroll.contentView.scroll(to: CGPoint(x: 0, y: min(oldOrigin.y, max(0, contentHeight - viewHeight))))
        scroll.reflectScrolledClipView(scroll.contentView)
        panel.orderFrontRegardless()
        Logger(subsystem: "local.augustine.DockPreview", category: "interaction")
            .info("panel_show visible=\(self.panel.isVisible) active_space=\(self.panel.isOnActiveSpace) app_active=\(NSApp.isActive) cards=\(records.count)")
    }
    var visibleRecords: [WindowRecord] {
        cards.filter { $0.frame.intersects(scroll.contentView.bounds) }.map(\.record)
    }
    func update(id: UUID, image: NSImage?, status: String) { cards.first { $0.record.id == id }?.update(image: image, status: status) }
    func error(_ message: String) { footer.stringValue = message }
    func hide() { panel.orderOut(nil); cards.forEach { $0.removeFromSuperview() }; cards.removeAll() }
    private func key(_ code: UInt16) {
        guard !cards.isEmpty else { return }
        switch code {
        case 53: onDismiss?(); return
        case 36, 76: onChoose?(cards[selectedIndex].record); return
        case 123: selectedIndex = max(0, selectedIndex - 1)
        case 124: selectedIndex = min(cards.count - 1, selectedIndex + 1)
        case 125: selectedIndex = min(cards.count - 1, selectedIndex + columns)
        case 126: selectedIndex = max(0, selectedIndex - columns)
        default: return
        }
        applySelection()
        document.scrollToVisible(cards[selectedIndex].frame)
    }
    private func applySelection() { for (index, card) in cards.enumerated() { card.selected = index == selectedIndex } }
}
