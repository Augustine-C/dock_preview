import AppKit
import ScreenCaptureKit
import PreviewCore
import os

@MainActor
final class CaptureService {
    private var cache = CostBoundedCache<String, NSImage>(costLimit: 32 * 1024 * 1024)
    private let logger = Logger(subsystem: "local.augustine.DockPreview", category: "capture")
    private var pressure: DispatchSourceMemoryPressure?
    private var keys: [UUID: String] = [:]
    init() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in self?.clear() }
        source.resume(); pressure = source
    }
    deinit { pressure?.cancel() }
    func cached(_ record: WindowRecord) -> NSImage? {
        guard let key = keys[record.id] else { return nil }
        return cache.value(for: key)
    }
    func clear() { keys.removeAll(); cache.removeAll() }
    func refresh(_ records: [WindowRecord], matchingAmong allRecords: [WindowRecord], valid: @escaping () -> Bool,
                 update: @escaping (UUID, NSImage?, String) -> Void) async {
        guard valid(), CGPreflightScreenCaptureAccess() else { return }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            guard valid() else { return }
            let candidates = content.windows.filter {
                $0.windowLayer == 0 && $0.frame.width > 40 && $0.frame.height > 40
            }
            let descriptors = candidates.map {
                WindowDescriptor(pid: $0.owningApplication?.processID ?? 0, title: $0.title ?? "", frame: $0.frame)
            }
            var pending: [(WindowRecord, SCWindow)] = []
            var used = Set<CGWindowID>()
            let axDescriptors = allRecords.map(\.descriptor)
            for record in records {
                guard let recordIndex = allRecords.firstIndex(where: { $0.id == record.id }) else { continue }
                let matched: Int?
                if let windowID = record.captureWindowID {
                    matched = candidates.firstIndex { $0.windowID == windowID && $0.owningApplication?.processID == record.pid }
                } else {
                    matched = record.menuOnly
                        ? WindowMatcher.mutuallyUniqueTitleMatch(at: recordIndex, windows: axDescriptors, candidates: descriptors)
                        : WindowMatcher.mutuallyUniqueMatch(at: recordIndex, windows: axDescriptors, candidates: descriptors)
                }
                guard let index = matched else {
                    logger.info("match_unavailable pid=\(record.pid) menu_only=\(record.menuOnly)")
                    update(record.id, cached(record), cached(record) == nil ? L10n.text("画面不可用") : L10n.text("缓存预览"))
                    continue
                }
                let window = candidates[index]
                guard used.insert(window.windowID).inserted else {
                    update(record.id, nil, L10n.text("画面匹配不明确")); continue
                }
                let key = "\(record.pid):\(window.windowID)"
                keys[record.id] = key
                // Keep the currently displayed preview during refresh. Publishing
                // cached status here would toggle the caption every two seconds.
                pending.append((record, window))
            }
            // Batches of two bound all in-flight screenshot work, including cancellation.
            for start in stride(from: 0, to: pending.count, by: 2) {
                guard valid(), !Task.isCancelled else { return }
                let first = pending[start]
                if start + 1 < pending.count {
                    let second = pending[start + 1]
                    async let a = screenshot(first.1)
                    async let b = screenshot(second.1)
                    let results = await (a, b)
                    guard valid() else { return }
                    deliver(results.0, record: first.0, update: update)
                    deliver(results.1, record: second.0, update: update)
                } else {
                    let result = await screenshot(first.1)
                    guard valid() else { return }
                    deliver(result, record: first.0, update: update)
                }
            }
            if keys.count > 256 { keys = keys.filter { id, _ in records.contains { $0.id == id } } }
        } catch {
            guard valid() else { return }
            for record in records { update(record.id, cached(record), L10n.text("截图暂不可用")) }
        }
    }
    private func screenshot(_ window: SCWindow) async -> CGImage? {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCScreenshotConfiguration()
        let scale = min(1, 640 / max(window.frame.width, window.frame.height))
        config.width = max(1, Int(window.frame.width * scale))
        config.height = max(1, Int(window.frame.height * scale))
        config.showsCursor = false; config.ignoreShadows = true
        config.includeChildWindows = false; config.dynamicRange = .sdr
        do {
            let output = try await SCScreenshotManager.captureScreenshot(contentFilter: filter, configuration: config)
            return output.sdrImage
        } catch {
            let failure = error as NSError
            logger.info("screenshot_failed window=\(window.windowID) domain=\(failure.domain, privacy: .public) code=\(failure.code)")
            return nil
        }
    }
    private func deliver(_ cg: CGImage?, record: WindowRecord, update: (UUID, NSImage?, String) -> Void) {
        guard let cg, let key = keys[record.id] else {
            update(record.id, cached(record), cached(record) == nil ? L10n.text("画面不可用") : L10n.text("缓存预览")); return
        }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        cache.insert(image, for: key, cost: cg.bytesPerRow * cg.height)
        update(record.id, image, "")
    }
}
