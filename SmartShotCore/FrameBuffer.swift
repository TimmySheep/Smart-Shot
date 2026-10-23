import Foundation
import CoreVideo

/// 有界内存帧缓冲：保存最近若干张高分辨率原始帧，供策略触发时回存。
///
/// 设计约束（任务书 §3.5）：
/// - 明确的内存预算（字节上限 + 帧数上限双限制）；
/// - 每帧带采集时间戳，支持按时间查找；
/// - 淘汰时记录事件（不得静默丢弃）；
/// - 不将每一帧写入磁盘。
///
/// 线程模型：内部锁保护，可从采集队列写入、策略队列读取。
public final class FrameBuffer {
    public struct Entry {
        public let pixelBuffer: CVPixelBuffer
        public let timestamp: TimeInterval
        public let width: Int
        public let height: Int
        let bytes: Int
    }

    private let maxEntries: Int
    private let maxBytes: Int
    private var entries: [Entry] = []
    private var currentBytes = 0
    private let lock = NSLock()

    /// 淘汰回调（在锁外触发时由调用方决定；此处同步调用，实现方只做记账）。
    public var onEvict: ((Entry, String) -> Void)?

    public init(maxEntries: Int = 8, maxBytes: Int = 192 * 1024 * 1024) {
        self.maxEntries = max(1, maxEntries)
        self.maxBytes = maxBytes
    }

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return entries.count
    }

    public var usedBytes: Int {
        lock.lock(); defer { lock.unlock() }
        return currentBytes
    }

    public func append(_ pixelBuffer: CVPixelBuffer, timestamp: TimeInterval) {
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let size = rowBytes * h
        let entry = Entry(pixelBuffer: pixelBuffer, timestamp: timestamp,
                          width: w, height: h, bytes: size)
        var evicted: [(Entry, String)] = []
        lock.lock()
        entries.append(entry)
        currentBytes += size
        while entries.count > maxEntries || currentBytes > maxBytes {
            let reason = entries.count > maxEntries
                ? "帧数超限（\(maxEntries)）"
                : "字节超限（\(maxBytes / 1024 / 1024)MB）"
            let removed = entries.removeFirst()
            currentBytes -= removed.bytes
            evicted.append((removed, reason))
        }
        lock.unlock()
        for (e, reason) in evicted {
            onEvict?(e, reason)
        }
    }

    /// 查找时间戳最接近（且不晚于）目标时刻的帧。
    public func frame(atOrBefore timestamp: TimeInterval) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        var best: Entry?
        for e in entries where e.timestamp <= timestamp + 0.000_1 {
            if best == nil || e.timestamp > best!.timestamp { best = e }
        }
        return best
    }

    /// 查找时间戳最接近目标时刻的帧（允许晚于目标，用于 fallback）。
    public func nearestFrame(to timestamp: TimeInterval) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        var best: Entry?
        for e in entries {
            if best == nil || abs(e.timestamp - timestamp) < abs(best!.timestamp - timestamp) {
                best = e
            }
        }
        return best
    }

    public func latest() -> Entry? {
        lock.lock(); defer { lock.unlock() }
        return entries.last
    }

    public func removeAll() {
        lock.lock()
        entries.removeAll()
        currentBytes = 0
        lock.unlock()
    }
}
