import Foundation
import CoreGraphics

public struct WindowDescriptor: Equatable, Sendable {
    public let pid: Int32
    public let title: String
    public let frame: CGRect
    public init(pid: Int32, title: String, frame: CGRect) {
        self.pid = pid; self.title = title; self.frame = frame
    }
}

public enum WindowMatcher {
    public static func mutuallyUniqueMatch(at index: Int, windows: [WindowDescriptor], candidates: [WindowDescriptor]) -> Int? {
        guard windows.indices.contains(index),
              let match = uniqueMatch(windows[index], candidates: candidates),
              uniqueMatch(candidates[match], candidates: windows) == index else { return nil }
        return match
    }
    /// Menu-only records have no geometry. Permit a screenshot only when both
    /// complete lists have exactly one occurrence of a nonempty title for the PID.
    /// This matches an image, never an operation target.
    public static func mutuallyUniqueTitleMatch(at index: Int, windows: [WindowDescriptor], candidates: [WindowDescriptor]) -> Int? {
        guard windows.indices.contains(index) else { return nil }
        let window = windows[index]
        let title = normalizedTitle(window.title)
        guard !title.isEmpty,
              windows.filter({ $0.pid == window.pid && normalizedTitle($0.title) == title }).count == 1 else { return nil }
        let matches = candidates.indices.filter { candidates[$0].pid == window.pid && normalizedTitle(candidates[$0].title) == title }
        return matches.count == 1 ? matches[0] : nil
    }
    private static func normalizedTitle(_ title: String) -> String {
        // Bidirectional isolates are formatting, not window-title identity.
        String(title.unicodeScalars.filter { !(0x2066...0x2069).contains($0.value) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Geometry breaks duplicate-title ties. An ambiguous match is deliberately omitted.
    public static func uniqueMatch(_ window: WindowDescriptor, candidates: [WindowDescriptor]) -> Int? {
        let sameProcess = candidates.indices.filter { candidates[$0].pid == window.pid }
        let geometry = sameProcess.filter { i in
            let f = candidates[i].frame, w = window.frame
            return abs(f.minX - w.minX) <= 3 && abs(f.minY - w.minY) <= 3
                && abs(f.width - w.width) <= 3 && abs(f.height - w.height) <= 3
        }
        let exact = geometry.filter { candidates[$0].title == window.title }
        if exact.count == 1 { return exact[0] }
        if exact.count > 1 { return nil }
        if geometry.count == 1 { return geometry[0] }
        // Title alone is unsafe: an unavailable/minimized AX window can share a title
        // with a different capturable window.
        return nil
    }
}

public enum DockEdge: Sendable { case bottom, left, right }
public enum PanelLayout {
    public static func columns(count: Int, screenWidth: CGFloat, cardWidth: CGFloat) -> Int {
        min(max(1, count), 3, max(1, Int((screenWidth - 32) / (cardWidth + 12))))
    }
    public static func frame(size: CGSize, anchor: CGRect, screen: CGRect, edge: DockEdge) -> CGRect {
        let w = min(size.width, max(1, screen.width - 16))
        let h = min(size.height, max(1, screen.height - 16))
        var x = anchor.midX - w / 2, y = anchor.maxY + 10
        switch edge {
        case .bottom: break
        case .left: x = anchor.maxX + 10; y = anchor.midY - h / 2
        case .right: x = anchor.minX - w - 10; y = anchor.midY - h / 2
        }
        x = min(max(x, screen.minX + 8), screen.maxX - w - 8)
        y = min(max(y, screen.minY + 8), screen.maxY - h - 8)
        return CGRect(x: x, y: y, width: w, height: h)
    }
    public static func bridge(anchor: CGRect, panel: CGRect) -> CGRect {
        // Narrow travel corridor, rather than the entire bounding box of both views.
        let x1 = max(panel.minX, min(anchor.midX, panel.maxX))
        let y1 = max(panel.minY, min(anchor.midY, panel.maxY))
        return CGRect(x: min(anchor.midX, x1) - 14, y: min(anchor.midY, y1) - 14,
                      width: abs(anchor.midX - x1) + 28, height: abs(anchor.midY - y1) + 28)
    }
}

public struct HoverState: Sendable {
    public private(set) var target: String?
    public private(set) var enteredAt: TimeInterval = 0
    public private(set) var generation: UInt64 = 0
    public private(set) var presented = false
    private var leftAt: TimeInterval?
    public init() {}
    public mutating func enter(_ target: String, at time: TimeInterval) {
        leftAt = nil
        guard self.target != target else { return }
        self.target = target; enteredAt = time; generation &+= 1; presented = false
    }
    public mutating func leave(at time: TimeInterval) { if leftAt == nil { leftAt = time } }
    public mutating func keep() { leftAt = nil }
    public func ready(at time: TimeInterval, delay: TimeInterval) -> Bool {
        target != nil && leftAt == nil && !presented && time - enteredAt >= delay
    }
    public mutating func markPresented() { presented = true }
    public func shouldHide(at time: TimeInterval, delay: TimeInterval = 0.2) -> Bool {
        leftAt.map { time - $0 >= delay } ?? false
    }
    public mutating func reset() {
        target = nil; leftAt = nil; presented = false; generation &+= 1
    }
    public func accepts(_ token: UInt64) -> Bool { token == generation && target != nil }
}

/// LRU storage with a deterministic payload budget (NSCache's cost limit is advisory).
public struct CostBoundedCache<Key: Hashable, Value> {
    private struct Entry { let value: Value; let cost: Int; var accessed: UInt64 }
    private var entries: [Key: Entry] = [:]
    private var serial: UInt64 = 0
    public private(set) var totalCost = 0
    public let costLimit: Int
    public let countLimit: Int
    public init(costLimit: Int, countLimit: Int = 128) {
        self.costLimit = max(0, costLimit); self.countLimit = max(1, countLimit)
    }
    public mutating func value(for key: Key) -> Value? {
        guard var entry = entries[key] else { return nil }
        serial &+= 1; entry.accessed = serial; entries[key] = entry
        return entry.value
    }
    public mutating func insert(_ value: Value, for key: Key, cost: Int) {
        let cost = max(0, cost)
        guard cost <= costLimit else { return }
        if let old = entries.removeValue(forKey: key) { totalCost -= old.cost }
        while totalCost + cost > costLimit || entries.count >= countLimit {
            guard let oldest = entries.min(by: { $0.value.accessed < $1.value.accessed })?.key,
                  let removed = entries.removeValue(forKey: oldest) else { break }
            totalCost -= removed.cost
        }
        serial &+= 1
        entries[key] = Entry(value: value, cost: cost, accessed: serial); totalCost += cost
    }
    public mutating func removeAll() { entries.removeAll(); totalCost = 0 }
}


public enum WindowEligibility {
    public static func includes(role: String?, subrole: String?, minimized: Bool, frame: CGRect?, minimizable: Bool = false) -> Bool {
        guard role == "AXWindow" else { return false }
        guard subrole == nil || subrole == "AXStandardWindow" || ((minimized || minimizable) && (subrole == "AXUnknown" || subrole == "AXDialog")) else { return false }
        // Minimized windows may no longer expose meaningful geometry. Their AX
        // object remains the authority for restoring and closing them.
        // A window's membership is independent of its current visibility/geometry.
        // Subroles and minimizability exclude transient UI instead of screen bounds.
        return true
    }
}
