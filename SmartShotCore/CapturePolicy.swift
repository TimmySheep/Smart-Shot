import Foundation

/// 策略层的一次决策输出。
public enum PolicyAction: Sendable {
    /// 保存指定帧（frameTimestamp 指向该帧；可能早于当前帧，如缓冲回存）。
    case save(frameTimestamp: TimeInterval, reason: TriggerReason, detail: String)
    /// 当前帧被纳入待定缓冲等待持续性确认。
    case pending(count: Int, needed: Int)
    /// 候选被丢弃（持续性未满足/判为过渡帧/被冷却或动态策略抑制）。
    case suppressed(detail: String, kind: JournalEvent.Kind)
}

/// 智能模式策略状态机：F 缓冲检测（持续性确认 + 回存 + 瞬变抢救）+ 定时保底
/// + 触发冷却 + 连续动态画面采样（实验性）。
///
/// 因果性：step 只接收按时间顺序到达的当前帧与自身状态，绝不使用未来帧。
/// 与研究 `p4_detector.py` 的 `DetBuffer` 语义对齐（replay 等价性测试保障）；
/// 动态采样、冷却为 App 层新增，研究未覆盖，replay 测试中默认关闭。
///
/// 线程模型：非线程安全，由单一采集队列串行驱动。
public final class CapturePolicy {
    public let params: DetectionParameters
    private let analyzer: RegionChangeAnalyzer

    // 最近一次“已保存”帧作为检测基准（对齐研究：与 last saved frame 比较）
    private var lastSavedFrame: GrayFrame?
    private var lastSavedT: TimeInterval?

    // 待定缓冲：(t, frame, total, peak)——只存低分辨率分析帧（320×180 = 57.6KB/帧）
    private var pending: [(t: TimeInterval, frame: GrayFrame, total: Int, peak: Int)] = []

    // 冷却
    private var lastSaveDecisionT: TimeInterval?

    // 连续动态画面状态
    public enum DynamicState: Sendable { case normal, dynamic }
    public private(set) var dynamicState: DynamicState = .normal
    private var consecutiveOverThreshold = 0
    private var consecutiveQuiet = 0
    private var lastDynamicSampleT: TimeInterval?

    // 统计（供 UI 与日志）
    public private(set) var framesSeen = 0
    public private(set) var stage1Hits = 0
    public private(set) var saveCount = 0
    /// 自上次保存以来被抑制的候选数（聚合后写入日志）。
    public private(set) var suppressedSinceLastSave = 0

    public init(params: DetectionParameters) {
        self.params = params
        self.analyzer = RegionChangeAnalyzer(params: params)
    }

    /// 会话开始/重置时调用。
    public func reset() {
        lastSavedFrame = nil
        lastSavedT = nil
        pending = []
        lastSaveDecisionT = nil
        dynamicState = .normal
        consecutiveOverThreshold = 0
        consecutiveQuiet = 0
        lastDynamicSampleT = nil
        framesSeen = 0
        stage1Hits = 0
        saveCount = 0
        suppressedSinceLastSave = 0
    }

    /// 输入一帧按时间顺序到达的分析帧，返回决策。
    /// - Parameter t: 该帧的采集时间戳（秒）。
    public func step(t: TimeInterval, frame: GrayFrame) -> [PolicyAction] {
        framesSeen += 1
        var actions: [PolicyAction] = []

        // 首帧
        guard let lastFrame = lastSavedFrame, let lastT = lastSavedT else {
            commitSave(t: t, frame: frame, reason: .firstFrame, detail: "首帧", into: &actions)
            return actions
        }

        // 1) 定时保底：与研究一致，心跳检查先于检测（<=0 表示关闭，对齐 Python 的 falsy 语义）。
        if params.heartbeatSeconds > 0, t - lastT >= params.heartbeatSeconds {
            if !pending.isEmpty {
                resolvePending(t: t, current: frame, why: "心跳前", into: &actions)
            }
            commitSave(t: t, frame: frame, reason: .heartbeat,
                       detail: String(format: "定时保底（%.0fs 无保存）", t - lastT), into: &actions)
            return actions
        }

        // 2) 两级检测（整帧一次计算，动态模式与正常路径共用结果）。
        let bits = analyzer.xorBits(frame, lastFrame)
        var total = 0, peak = 0
        var over = false
        if bits >= params.prefilterBits {
            stage1Hits += 1
            let rc = analyzer.regionCounts(cur: frame, ref: lastFrame)
            total = rc.total
            peak = rc.peak
            over = total > params.pagePixels || peak > params.regionPeak
        }

        // 3) 连续动态画面：动态模式下不逐帧触发，按采样间隔保存。
        if params.dynamicEnabled && dynamicState == .dynamic {
            if over {
                consecutiveQuiet = 0
                consecutiveOverThreshold += 1
            } else {
                consecutiveQuiet += 1
                consecutiveOverThreshold = 0
            }
            if consecutiveQuiet >= params.dynamicExitQuietFrames {
                dynamicState = .normal
                lastDynamicSampleT = nil
                commitSave(t: t, frame: frame, reason: .dynamicEnd,
                           detail: "连续动态画面结束（\(consecutiveQuiet) 帧安静）",
                           into: &actions)
                return actions
            }
            if lastDynamicSampleT == nil || t - lastDynamicSampleT! >= params.dynamicSampleSeconds {
                lastDynamicSampleT = t
                commitSave(t: t, frame: frame, reason: .dynamicSample,
                           detail: String(format: "动态画面采样（每 %.0fs）", params.dynamicSampleSeconds),
                           into: &actions)
                return actions
            }
            noteSuppressed()
            actions.append(.suppressed(detail: "动态画面采样间隔内抑制", kind: .suppressed))
            return actions
        }

        // 4) 预筛未命中：信号回落，处理待定。
        if !over {
            if !pending.isEmpty {
                resolvePending(t: t, current: frame,
                               why: bits < params.prefilterBits ? "预筛未命中" : "信号回落",
                               into: &actions)
            }
            if params.dynamicEnabled {
                consecutiveQuiet += 1
                consecutiveOverThreshold = 0
            }
            return actions
        }

        // 5) 动态模式进入判断（研究未覆盖，实验性）
        if params.dynamicEnabled {
            consecutiveQuiet = 0
            consecutiveOverThreshold += 1
            if consecutiveOverThreshold >= params.dynamicEnterFrames {
                dynamicState = .dynamic
                lastDynamicSampleT = t
                commitSave(t: t, frame: frame, reason: .dynamicStart,
                           detail: "连续 \(consecutiveOverThreshold) 帧高频变化，进入动态采样",
                           into: &actions)
                return actions
            }
        }

        // 6) 冷却检查（研究配置 cooldown=0，此处为 App 层新增）
        if params.cooldownSeconds > 0,
           let lastDecision = lastSaveDecisionT,
           t - lastDecision < params.cooldownSeconds {
            noteSuppressed()
            actions.append(.suppressed(
                detail: String(format: "冷却中（%.1fs / %.1fs）", t - lastDecision, params.cooldownSeconds),
                kind: .suppressed))
            return actions
        }

        // 7) 持续性确认 + 缓冲回存（研究 F_buffer 核心）
        pending.append((t, frame, total, peak))
        let need = max(1, params.persistFrames)
        if pending.count >= need {
            let first = pending[0]
            pending.removeAll()
            commitSave(t: first.t, frame: first.frame, reason: .smartChange,
                       detail: "缓冲回存：持续 \(need) 帧确认（延迟 \(String(format: "%.1f", t - first.t))s）；"
                             + "总像素 \(first.total) / 峰值分区 \(first.peak)",
                       decisionT: t, into: &actions)
        } else {
            actions.append(.pending(count: pending.count, needed: need))
        }
        return actions
    }

    // MARK: - 私有

    private func commitSave(t: TimeInterval, frame: GrayFrame, reason: TriggerReason,
                            detail: String, into actions: inout [PolicyAction]) {
        commitSave(t: t, frame: frame, reason: reason, detail: detail, decisionT: t, into: &actions)
    }

    private func commitSave(t: TimeInterval, frame: GrayFrame, reason: TriggerReason,
                            detail: String, decisionT: TimeInterval, into actions: inout [PolicyAction]) {
        lastSavedFrame = frame
        lastSavedT = t
        lastSaveDecisionT = decisionT
        saveCount += 1
        pending.removeAll()
        // 注意：不清零 consecutiveOverThreshold——动态进入判断按"连续超阈值帧"计数，
        // 期间的保存（如缓冲回存）不应打断连续计数；清零由动态状态机自身负责。
        consecutiveQuiet = 0
        if suppressedSinceLastSave > 0 {
            actions.append(.suppressed(
                detail: "自上次保存以来共抑制 \(suppressedSinceLastSave) 个候选", kind: .suppressed))
            suppressedSinceLastSave = 0
        }
        actions.append(.save(frameTimestamp: t, reason: reason, detail: detail))
    }

    /// 持续性未满足时的瞬变抢救/过渡帧丢弃（研究 blip rescue，后验探索性逻辑）。
    private func resolvePending(t: TimeInterval, current: GrayFrame, why: String,
                                into actions: inout [PolicyAction]) {
        guard let first = pending.first else { return }
        if params.blipRescue && pending.count == 1 {
            let dCur = analyzer.xorBits(first.frame, current)
            if dCur >= params.prefilterBits {
                pending.removeAll()
                commitSave(t: first.t, frame: first.frame, reason: .blipRescue,
                           detail: "瞬变抢救：待定帧显著异于历史基准和当前帧（\(why)），"
                                 + "帧间差异 \(dCur) 位，延迟 \(String(format: "%.1f", t - first.t))s",
                           decisionT: t, into: &actions)
                return
            }
            pending.removeAll()
            noteSuppressed()
            actions.append(.suppressed(
                detail: "放弃待定（\(why)）：与当前帧差异仅 \(dCur) 位，判为过渡帧",
                kind: .discardedPending))
            return
        }
        let count = pending.count
        pending.removeAll()
        noteSuppressed()
        actions.append(.suppressed(
            detail: "放弃待定 \(first.t)（\(why)）：持续性未满足（\(count) 帧）",
            kind: .discardedPending))
    }

    private func noteSuppressed() {
        suppressedSinceLastSave += 1
    }
}
