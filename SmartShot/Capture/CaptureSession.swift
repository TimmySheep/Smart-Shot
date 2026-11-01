import QuartzCore
import SmartShotCore
import Foundation
import CoreVideo
import Combine

/// 一次运行会话的对外状态快照。
public struct SessionStatus: Sendable {
    public enum Phase: String, Sendable { case idle, running, stopping, error }
    public var phase: Phase = .idle
    public var startedAt: Date?
    public var savedCount = 0
    public var lastSaveAt: Date?
    public var lastSaveReason: TriggerReason?
    public var lastSaveDetail: String = ""
    public var lastError: String?
    public var detectionState: String = "—"
    public var framesProcessed = 0
    public var analyzerMillisAvg: Double = 0
    public var analyzerMillisMax: Double = 0
    public var bufferUsedBytes: Int = 0
    public var bufferEntries: Int = 0
    public var dynamicMode = false
    /// 实际采集像素尺寸（首帧后填充）。
    public var captureWidth: Int = 0
    public var captureHeight: Int = 0

    public var uptime: TimeInterval {
        guard let startedAt else { return 0 }
        return Date().timeIntervalSince(startedAt)
    }
}

/// 会话编排器：CaptureService → 灰度化 → CapturePolicy → FrameBuffer → CaptureWriter → EventJournal。
///
/// 线程模型：
///  - 采集回调（capture queue）：灰度化 + 策略判定 + 入缓冲，全程串行；
///  - 写入（writer queue）：PNG 编码 + 落盘 + SHA-256，异步不阻塞采集；
///  - 状态发布（main）：@Published status 供 UI 观察。
public final class CaptureSession: ObservableObject {
    @Published public private(set) var status = SessionStatus()

    public let params: DetectionParameters
    /// 实际使用的目标；窗口 ID 失效被重新解析后会更新为新窗口及其实时像素尺寸。
    public private(set) var target: CaptureTargetID
    public let writer: CaptureWriter
    public let journal: EventJournal
    public let mode: CaptureMode

    private let captureService = CaptureService()
    private let policy: CapturePolicy
    private let buffer: FrameBuffer
    private let captureQueue = DispatchQueue(label: "com.smartshot.session.pipeline", qos: .userInitiated)
    private let writerQueue = DispatchQueue(label: "com.smartshot.session.writer", qos: .utility)
    private var targetWatchTimer: DispatchSourceTimer?
    private var lastTimedSaveT: TimeInterval = -.greatestFiniteMagnitude
    private var lastFrameArrivalT: TimeInterval?
    private var stallReported = false
    private let appVersion: String

    /// 写入失败后的停止回调（磁盘满等致命错误）。
    public var onFatalWriteError: ((Error) -> Void)?
    /// 启动后目标被重新解析（窗口重建/实时像素尺寸与旧记录不同）时回调，用于回写设置。
    public var onTargetResolved: ((CaptureTargetID) -> Void)?

    public init(target: CaptureTargetID, mode: CaptureMode, params: DetectionParameters,
                writer: CaptureWriter, journal: EventJournal, appVersion: String = "0.1.0") {
        self.target = target
        self.mode = mode
        self.params = params
        self.writer = writer
        self.journal = journal
        self.policy = CapturePolicy(params: params)
        self.buffer = FrameBuffer(maxEntries: max(4, Int(params.detectionFPS * 4) + 2))
        self.appVersion = appVersion

        buffer.onEvict = { [weak self] entry, reason in
            self?.journal.append(JournalEvent(
                kind: .bufferOverflow, timestamp: entry.timestamp,
                message: "帧缓冲淘汰 \(String(format: "%.2f", entry.timestamp))s（\(reason)）",
                data: ["ts": String(entry.timestamp)]))
        }
    }

    // MARK: - 生命周期

    public func start() {
        guard status.phase == .idle || status.phase == .error else { return }
        let requested = target
        let resolved: CaptureTargetID
        do {
            resolved = try captureService.start(target: requested, fps: params.detectionFPS)
        } catch {
            journal.append(JournalEvent(kind: .sessionStart, timestamp: Date().timeIntervalSince1970,
                                        message: "会话开始失败：\(mode == .smart ? "智能" : "定时")模式，目标 \(requested.displayName)",
                                        data: ["mode": mode.rawValue, "target": requested.displayName]))
            fail(error)
            return
        }
        self.target = resolved

        journal.append(JournalEvent(kind: .sessionStart, timestamp: Date().timeIntervalSince1970,
                                    message: "会话开始：\(mode == .smart ? "智能" : "定时")模式，"
                                           + "目标 \(resolved.displayName)（\(resolved.pixelWidth)×\(resolved.pixelHeight) 像素）",
                                    data: ["mode": mode.rawValue, "target": resolved.displayName,
                                           "captureWidth": String(resolved.pixelWidth),
                                           "captureHeight": String(resolved.pixelHeight)]))
        if resolved.id != requested.id
            || resolved.pixelWidth != requested.pixelWidth
            || resolved.pixelHeight != requested.pixelHeight {
            let callback = onTargetResolved
            DispatchQueue.main.async { callback?(resolved) }
        }

        policy.reset()
        buffer.removeAll()
        captureService.onFrame = { [weak self] pb, ts in
            self?.captureQueue.async { self?.processFrame(pb, ts) }
        }
        captureService.onError = { [weak self] error in
            self?.fail(error)
        }

        let startInfo = SessionStatus()
        let captureW = resolved.pixelWidth, captureH = resolved.pixelHeight
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.status = startInfo
            self.status.phase = .running
            self.status.startedAt = Date()
            self.status.detectionState = self.mode == .smart ? "检测中" : "定时"
            self.status.captureWidth = captureW
            self.status.captureHeight = captureH
        }
        startTargetWatch()
    }

    /// 供外部（如 AppState）报告启动期错误。
    public func reportError(_ message: String) {
        DispatchQueue.main.async {
            self.status.phase = .error
            self.status.lastError = message
        }
    }

    public func stop() {
        guard status.phase == .running else { return }
        DispatchQueue.main.async { self.status.phase = .stopping }
        targetWatchTimer?.cancel()
        targetWatchTimer = nil
        captureService.stop()
        journal.append(JournalEvent(kind: .sessionStop, timestamp: Date().timeIntervalSince1970,
                                    message: "会话停止，共保存 \(status.savedCount) 张"))
        journal.flush()
        DispatchQueue.main.async { self.status.phase = .idle }
    }

    /// 手动立即保存一张（不走检测）。
    public func saveManual() {
        guard let entry = buffer.latest() else { return }
        enqueueSave(entry: entry, decisionT: CACurrentMediaTime(),
                    reason: .manual, detail: "手动保存")
    }

    // MARK: - 帧管线（capture queue 串行）

    private func processFrame(_ pb: CVPixelBuffer, _ ts: TimeInterval) {
        guard status.phase == .running || status.phase == .stopping else { return }
        let t0 = DispatchTime.now()
        lastFrameArrivalT = CACurrentMediaTime()
        stallReported = false

        // 首帧后回读真实采集尺寸，仅用于状态展示（真正的尺寸已在 start() 由实时几何确定，
        // 这里不在采集队列上改写 target，避免与写入队列竞争）。
        if let actual = captureService.captureSize,
           actual.width != status.captureWidth || actual.height != status.captureHeight {
            let w = actual.width, h = actual.height
            DispatchQueue.main.async {
                self.status.captureWidth = w
                self.status.captureHeight = h
            }
        }

        guard let gray = GrayConverter.convert(pb, targetWidth: params.analysisWidth,
                                               targetHeight: params.analysisHeight) else {
            journal.append(JournalEvent(kind: .runtime, timestamp: ts,
                                        message: "灰度转换失败（帧丢弃）"))
            return
        }

        // 定时模式：不跑检测，按间隔保存（统一使用帧时间戳，host time 域）
        if mode == .timed {
            if let copy = Self.copyPixelBuffer(pb) { buffer.append(copy, timestamp: ts) }
            if status.savedCount == 0 || ts - lastTimedSaveT >= params.timedIntervalSeconds {
                lastTimedSaveT = ts
                if let entry = buffer.frame(atOrBefore: ts) {
                    enqueueSave(entry: entry, decisionT: ts, reason: .timed,
                                detail: String(format: "定时保存（每 %.0fs）", params.timedIntervalSeconds))
                }
            }
            updateAnalyzerTiming(t0)
            updateBufferStats()
            return
        }

        // 智能模式：先检测，再决定是否入缓冲
        let actions = policy.step(t: ts, frame: gray)
        // 必须入缓冲自己的副本：直接持有 SCK 的像素缓冲会占满采集池（queueDepth），
        // 流会在几帧后无声停摆（心跳也随之停止），表现为“画面变了但不再截图”。
        if let copy = Self.copyPixelBuffer(pb) {
            buffer.append(copy, timestamp: ts)
        } else {
            journal.append(JournalEvent(kind: .runtime, timestamp: ts,
                                        message: "帧复制失败（本帧不入缓冲，检测结果仍生效）"))
        }

        for action in actions {
            switch action {
            case .save(let frameT, let reason, let detail):
                // 从缓冲取对应帧（可能早于当前帧：缓冲回存/瞬变抢救）
                let entry = buffer.frame(atOrBefore: frameT) ?? buffer.nearestFrame(to: frameT)
                if let entry {
                    enqueueSave(entry: entry, decisionT: ts, reason: reason, detail: detail)
                } else {
                    // 缓冲已淘汰该帧：记账并用最近帧兜底（不得静默丢失）
                    journal.append(JournalEvent(
                        kind: .bufferOverflow, timestamp: ts,
                        message: "目标帧 \(String(format: "%.2f", frameT))s 已被缓冲淘汰，"
                               + "改用最近帧兜底（\(reason.rawValue)）"))
                    if let fallback = buffer.nearestFrame(to: ts) {
                        enqueueSave(entry: fallback, decisionT: ts,
                                    reason: .fallbackResave,
                                    detail: "\(detail)；原帧已被淘汰")
                    }
                }
            case .pending(let count, let needed):
                DispatchQueue.main.async {
                    self.status.detectionState = "待确认 \(count)/\(needed)"
                }
            case .suppressed(let detail, let kind):
                journal.append(JournalEvent(kind: kind, timestamp: ts, message: detail))
            }
        }
        updateAnalyzerTiming(t0)
        updateBufferStats()
        DispatchQueue.main.async {
            self.status.framesProcessed = self.policy.framesSeen
            self.status.dynamicMode = self.policy.dynamicState == .dynamic
            if self.status.detectionState != "待确认" {
                self.status.detectionState = self.policy.dynamicState == .dynamic ? "动态采样" : "检测中"
            }
        }
    }

    private func enqueueSave(entry: FrameBuffer.Entry, decisionT: TimeInterval,
                             reason: TriggerReason, detail: String) {
        let pixelBuffer = entry.pixelBuffer
        let frameT = entry.timestamp
        writerQueue.async { [weak self] in
            guard let self else { return }
            do {
                let outcome = try self.writer.save(
                    pixelBuffer: pixelBuffer, frameTimestamp: frameT,
                    decisionTimestamp: decisionT, reason: reason,
                    reasonDetail: detail, target: self.target, parameters: self.params)
                guard let outcome else {
                    // 磁盘策略跳过
                    self.journal.append(JournalEvent(kind: .diskFull, timestamp: Date().timeIntervalSince1970,
                                                     message: "磁盘空间不足，跳过一张（\(reason.rawValue)）"))
                    return
                }
                let meta = outcome.metadata
                self.journal.append(JournalEvent(kind: .shot, timestamp: meta.captureFrameTimestamp,
                                                 message: "\(meta.reason.rawValue)：\(meta.filename)",
                                                 shot: meta))
                DispatchQueue.main.async {
                    self.status.savedCount += 1
                    // 帧时间戳是 host-time 域，展示用写入完成时刻
                    self.status.lastSaveAt = Date()
                    self.status.lastSaveReason = meta.reason
                    self.status.lastSaveDetail = meta.reasonDetail
                }
            } catch {
                self.journal.append(JournalEvent(kind: .runtime, timestamp: Date().timeIntervalSince1970,
                                                 message: "写入失败：\(error.localizedDescription)"))
                if case CaptureWriterError.diskSpaceLow = error {
                    DispatchQueue.main.async { self.status.phase = .error }
                    self.onFatalWriteError?(error)
                    self.captureService.stop()
                }
            }
        }
    }

    // MARK: - 帧复制

    /// 把 SCK 交付的像素缓冲复制成自己的 CVPixelBuffer。
    ///
    /// ScreenCaptureKit 的缓冲来自有限池；长期持有会把池耗尽、流静默停摆。
    /// 复制后原始缓冲随采样回调返回即可被回收。
    static func copyPixelBuffer(_ pb: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(pb)
        let height = CVPixelBufferGetHeight(pb)
        let format = CVPixelBufferGetPixelFormatType(pb)
        var dst: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: format]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, format,
                                  attrs as CFDictionary, &dst) == kCVReturnSuccess,
              let dst else { return nil }

        CVPixelBufferLockBaseAddress(pb, .readOnly)
        CVPixelBufferLockBaseAddress(dst, [])
        defer {
            CVPixelBufferUnlockBaseAddress(dst, [])
            CVPixelBufferUnlockBaseAddress(pb, .readOnly)
        }
        guard let srcBase = CVPixelBufferGetBaseAddress(pb),
              let dstBase = CVPixelBufferGetBaseAddress(dst) else { return nil }
        let srcRow = CVPixelBufferGetBytesPerRow(pb)
        let dstRow = CVPixelBufferGetBytesPerRow(dst)
        let copyBytes = min(srcRow, dstRow)
        for y in 0..<height {
            memcpy(dstBase.advanced(by: y * dstRow), srcBase.advanced(by: y * srcRow), copyBytes)
        }
        return dst
    }

    // MARK: - 巡检与统计

    private func startTargetWatch() {
        let timer = DispatchSource.makeTimerSource(queue: captureQueue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self, self.status.phase == .running else { return }
            // 采集流停摆检测：心跳依赖帧到达，帧断了会静默失去保底，必须记账。
            if let last = self.lastFrameArrivalT,
               CACurrentMediaTime() - last > 5, !self.stallReported {
                self.stallReported = true
                self.journal.append(JournalEvent(
                    kind: .runtime, timestamp: Date().timeIntervalSince1970,
                    message: String(format: "已 %.0f 秒未收到采集帧（采集流可能停摆）",
                                    CACurrentMediaTime() - last)))
            }
            guard self.target.kind == .window else { return }
            Task {
                let exists = await CaptureService.targetStillExists(self.target)
                if !exists {
                    self.journal.append(JournalEvent(kind: .targetLost, timestamp: Date().timeIntervalSince1970,
                                                     message: "目标窗口已关闭或不可见，采集流将停止"))
                    self.fail(CaptureServiceError.contentUnavailable("目标窗口已关闭"))
                }
            }
        }
        timer.resume()
        targetWatchTimer = timer
    }

    private func updateAnalyzerTiming(_ t0: DispatchTime) {
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000
        DispatchQueue.main.async {
            self.status.analyzerMillisAvg = self.status.analyzerMillisAvg * 0.9 + ms * 0.1
            self.status.analyzerMillisMax = max(self.status.analyzerMillisMax, ms)
        }
    }

    private func updateBufferStats() {
        let bytes = buffer.usedBytes
        let count = buffer.count
        DispatchQueue.main.async {
            self.status.bufferUsedBytes = bytes
            self.status.bufferEntries = count
        }
    }

    private func fail(_ error: Error) {
        captureService.stop()
        targetWatchTimer?.cancel()
        targetWatchTimer = nil
        journal.append(JournalEvent(kind: .runtime, timestamp: Date().timeIntervalSince1970,
                                    message: "会话异常：\(error.localizedDescription)"))
        DispatchQueue.main.async {
            self.status.phase = .error
            self.status.lastError = error.localizedDescription
        }
    }
}
