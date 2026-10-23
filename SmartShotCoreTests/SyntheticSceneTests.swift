import XCTest
@testable import SmartShotCore

/// 离线合成场景测试（任务书 §5.1）：不依赖真实视频，程序生成 320×180 灰度帧，
/// 验证检测器在各类场景下的触发/不触发/漏检行为。
final class SyntheticSceneTests: XCTestCase {

    // 场景基底：一张类似幻灯片的静态图（文字块 + 图表）
    private func baseFrame() -> GrayFrame {
        var bytes = [UInt8](repeating: 240, count: 320 * 180)
        // 标题区
        for r in 20..<30 { for c in 30..<200 { bytes[r * 320 + c] = 40 } }
        // 正文行
        for line in 0..<6 {
            for r in (50 + line * 12)..<(54 + line * 12) {
                for c in 30..<280 { bytes[r * 320 + c] = 80 }
            }
        }
        // 图表区
        for r in 130..<165 { for c in 200..<300 { bytes[r * 320 + c] = 120 } }
        return GrayFrame(width: 320, height: 180, bytes: bytes)
    }

    private func write(_ f: GrayFrame, rect: (x: Int, y: Int, w: Int, h: Int), value: UInt8) -> GrayFrame {
        var b = f.bytes
        for r in rect.y..<(rect.y + rect.h) {
            for c in rect.x..<(rect.x + rect.w) {
                b[r * 320 + c] = value
            }
        }
        return GrayFrame(width: 320, height: 180, bytes: b)
    }

    private func run(_ frames: [(t: TimeInterval, f: GrayFrame)],
                     params: DetectionParameters = DetectionParameters()) -> [PolicyAction] {
        let policy = CapturePolicy(params: params)
        var all: [PolicyAction] = []
        for item in frames { all.append(contentsOf: policy.step(t: item.t, frame: item.f)) }
        return all
    }

    private func saves(_ actions: [PolicyAction]) -> [TimeInterval] {
        actions.compactMap { if case .save(let t, _, _) = $0 { return t }; return nil }
    }

    // MARK: 完全相同图像

    func testIdenticalFramesNoSmartTrigger() {
        let f = baseFrame()
        let frames = (0..<20).map { (t: TimeInterval($0), f: f) }
        let s = saves(run(frames))
        // 首帧保存 + 保底触发（10s 间隔 → t=10 触发一次），中间无智能触发
        XCTAssertEqual(s.first, 0)
        XCTAssertTrue(s.contains(10), "10 秒保底应在 t=10 触发")
        XCTAssertFalse(s.contains(5), "静态画面不应有智能触发")
    }

    // MARK: 仅鼠标位置不同

    func testMouseOnlyChangeSuppressedByRegionThreshold() {
        let base = baseFrame()
        // 鼠标指针约 3×4 像素（320 宽下），单分区峰值 ≈12 像素 < 20
        let withMouse = write(base, rect: (100, 80, 3, 4), value: 10)
        let frames: [(t: TimeInterval, f: GrayFrame)] = [
            (0, base), (1, base), (2, withMouse), (3, withMouse),
            (4, write(base, rect: (140, 90, 3, 4), value: 10)), (5, base),
        ]
        let s = saves(run(frames))
        // persist=2：鼠标帧只出现 1 帧连续不足；移动后再来一帧不同位置——
        // 但与 last saved（base）的差值每个分区都低于阈值 → 不应触发
        XCTAssertFalse(s.contains(2), "单像素级鼠标移动不应触发（峰值 12 < 20）")
        XCTAssertFalse(s.contains(3))
    }

    // MARK: 播放器进度条变化

    func testProgressBarSmallChange() {
        let base = baseFrame()
        // 进度条：底部 2 行、宽 40 像素的条带推进（总 80 像素，单分区最多 40）
        let f1 = write(base, rect: (30, 174, 40, 2), value: 200)
        let f2 = write(base, rect: (30, 174, 80, 2), value: 200)
        let frames: [(t: TimeInterval, f: GrayFrame)] = [
            (0, base), (1, f1), (2, f2), (3, f2), (4, f2),
        ]
        // 注意：174 行在 Dock 排除区（171+）——进度条在排除区不应触发
        let s = saves(run(frames))
        XCTAssertFalse(s.contains(1), "排除区（Dock 行）内的进度条变化不应触发")
    }

    // MARK: 文字发生变化
    //
    // 冻结参数下第一级预筛是硬门槛：XOR 位数 < 8000 的变化根本不会进入区域分析。
    // 一行 250×8 像素的正文改写（灰度 80/240 → 15）产生 ~14000 位，方能通过预筛。
    // 这与研究实测一致：单行小范围改动若像素太少会被预筛挡掉（见"已知限制"测试）。

    func testTextChangeTriggers() {
        let base = baseFrame()
        // 正文一行改写：8 行 × 250 像素，高对比（→15）
        let changed = write(base, rect: (30, 50, 250, 8), value: 15)
        let frames: [(t: TimeInterval, f: GrayFrame)] = [
            (0, base), (1, base), (2, changed), (3, changed),
        ]
        let s = saves(run(frames))
        XCTAssertTrue(s.contains(2), "文字区域变化应触发保存（缓冲回存到变化首帧 t=2）")
    }

    // MARK: PPT 整页切换

    func testFullPageSwitchTriggers() {
        let base = baseFrame()
        // 整页变成另一页（页面级变化，total > 3000）
        var bytes = [UInt8](repeating: 30, count: 320 * 180)
        for r in 60..<70 { for c in 50..<270 { bytes[r * 320 + c] = 230 } }
        let page2 = GrayFrame(width: 320, height: 180, bytes: bytes)
        let frames: [(t: TimeInterval, f: GrayFrame)] = [
            (0, base), (1, base), (2, page2), (3, page2),
        ]
        let s = saves(run(frames))
        XCTAssertTrue(s.contains(2), "整页切换应触发")
    }

    // MARK: 公式局部变化

    func testFormulaLocalChangeTriggers() {
        let base = baseFrame()
        // 公式区新增一行推导：100×26 像素高对比变化（~15600 位，稳过预筛）
        let changed = write(base, rect: (100, 92, 100, 26), value: 15)
        let frames: [(t: TimeInterval, f: GrayFrame)] = [
            (0, base), (1, base), (2, changed), (3, changed),
        ]
        let s = saves(run(frames))
        XCTAssertTrue(s.contains(2), "公式局部变化（保守策略）应触发")
    }

    // MARK: 手写批注出现

    func testDenseAnnotationTriggers() {
        let base = baseFrame()
        var b = base.bytes
        // 密集批注块：1200 像素高对比（→15，每像素 8 位 XOR）= 9600 位，过预筛
        for r in 80..<100 { for c in 60..<120 { b[r * 320 + c] = 15 } }
        let annotated = GrayFrame(width: 320, height: 180, bytes: b)
        let frames: [(t: TimeInterval, f: GrayFrame)] = [
            (0, base), (1, base), (2, annotated), (3, annotated),
        ]
        let s = saves(run(frames))
        XCTAssertTrue(s.contains(2), "密集批注出现应触发")
    }

    /// 已知限制（如实记录，非缺陷）：细笔画批注 XOR 位数不足预筛阈值会漏检。
    /// 冻结参数 prefilter=8000 是研究在误报/漏检间选定的折中；
    /// 480 像素的细斜线只产生 ~1500-3800 位，被第一级预筛挡掉。
    func testThinAnnotationMissedWithFrozenPrefilter() {
        let base = baseFrame()
        var b = base.bytes
        for d in 0..<40 {
            let r = 90 + d / 2, c = 60 + d
            b[r * 320 + c] = 200
            b[(r + 1) * 320 + c] = 200
        }
        let annotated = GrayFrame(width: 320, height: 180, bytes: b)
        let frames: [(t: TimeInterval, f: GrayFrame)] = [
            (0, base), (1, base), (2, annotated), (3, annotated),
        ]
        let s = saves(run(frames))
        XCTAssertFalse(s.contains(2),
                       "已知限制：细笔画（<8000 位）被预筛挡掉，冻结配置下确实漏检")
    }

    // MARK: 图表局部变化

    func testChartLocalChangeTriggers() {
        let base = baseFrame()
        // 图表区重绘 60×25 像素：灰度 120→15（每像素 6 位 XOR）= 9000 位过预筛
        let changed = write(base, rect: (210, 135, 60, 25), value: 15)
        let frames: [(t: TimeInterval, f: GrayFrame)] = [
            (0, base), (1, base), (2, changed), (3, changed),
        ]
        let s = saves(run(frames))
        XCTAssertTrue(s.contains(2), "图表局部变化应触发")
    }

    // MARK: 一秒左右的短暂画面（blip rescue）

    func testOneSecondBlipRescued() {
        let base = baseFrame()
        var bytes = [UInt8](repeating: 10, count: 320 * 180)
        for r in 40..<140 { for c in 40..<280 { bytes[r * 320 + c] = 240 } }
        let blip = GrayFrame(width: 320, height: 180, bytes: bytes)
        // X → Y（1 帧）→ X：persist=2 凑不满，但 blip rescue 应回存 Y
        let frames: [(t: TimeInterval, f: GrayFrame)] = [
            (0, base), (1, base), (2, blip), (3, base), (4, base),
        ]
        let actions = run(frames)
        let s = saves(actions)
        XCTAssertTrue(s.contains(2), "短暂 1 秒画面应被瞬变抢救保存")
        // 检查触发原因是 blipRescue
        let blipSaves = actions.compactMap { a -> Bool in
            if case .save(let t, let reason, _) = a, t == 2 { return reason == .blipRescue }
            return false
        }
        XCTAssertTrue(blipSaves.contains(true), "该保存的原因应为瞬变抢救")
    }

    // MARK: blip rescue 关闭时漏检（记录已知风险）

    func testBlipMissedWhenRescueDisabled() {
        var p = DetectionParameters()
        p.blipRescue = false
        let base = baseFrame()
        var bytes = [UInt8](repeating: 10, count: 320 * 180)
        for r in 40..<140 { for c in 40..<280 { bytes[r * 320 + c] = 240 } }
        let blip = GrayFrame(width: 320, height: 180, bytes: bytes)
        let frames: [(t: TimeInterval, f: GrayFrame)] = [
            (0, base), (1, base), (2, blip), (3, base), (4, base),
        ]
        let s = saves(run(frames, params: p))
        XCTAssertFalse(s.contains(2), "关闭抢救时 1 秒画面会漏检（已知风险）")
    }

    // MARK: 连续动态画面 → 进入动态采样

    func testContinuousDynamicEntersSampling() {
        var p = DetectionParameters()
        p.dynamicEnabled = true
        p.dynamicEnterFrames = 4
        p.dynamicSampleSeconds = 5
        p.dynamicExitQuietFrames = 3
        p.heartbeatSeconds = 60   // 拉长心跳，专门观察动态逻辑
        let base = baseFrame()
        // 每帧都大变化（模拟影片）：8 帧
        var dynamic: [GrayFrame] = []
        for k in 0..<8 {
            var b = base.bytes
            for r in 0..<180 { for c in 0..<320 where (c + r * 3 + k * 7) % 5 == 0 { b[r * 320 + c] = UInt8((k * 40) % 250) } }
            dynamic.append(GrayFrame(width: 320, height: 180, bytes: b))
        }
        var frames: [(t: TimeInterval, f: GrayFrame)] = [(0, base), (1, base)]
        for (k, f) in dynamic.enumerated() { frames.append((TimeInterval(2 + k), f)) }
        // 之后 4 帧安静
        for k in 0..<4 { frames.append((TimeInterval(10 + k), base)) }

        let actions = run(frames, params: p)
        let reasons = actions.compactMap { a -> TriggerReason? in
            if case .save(_, let r, _) = a { return r }
            return nil
        }
        XCTAssertTrue(reasons.contains(.dynamicStart), "连续高频变化应触发进入动态模式")
        XCTAssertTrue(reasons.contains(.dynamicSample), "动态模式下应有采样保存")
        XCTAssertTrue(reasons.contains(.dynamicEnd), "画面安静后应触发动态结束")
    }

    // MARK: 心跳保底

    func testHeartbeatFires() {
        var p = DetectionParameters()
        p.heartbeatSeconds = 10
        let base = baseFrame()
        let frames = (0..<35).map { (t: TimeInterval($0), f: base) }
        let s = saves(run(frames, params: p))
        XCTAssertEqual(s, [0, 10, 20, 30], "静态画面应按 10 秒间隔保底")
    }

    // MARK: 冷却抑制

    func testCooldownSuppresses() {
        var p = DetectionParameters()
        p.cooldownSeconds = 5
        p.heartbeatSeconds = 60
        let base = baseFrame()
        // 变化均需过预筛（≥8000 位）：正文行改写级
        let c1 = write(base, rect: (30, 50, 250, 8), value: 15)
        let c2 = write(base, rect: (30, 62, 250, 12), value: 15)
        let c3 = write(base, rect: (30, 74, 250, 8), value: 15)
        let frames: [(t: TimeInterval, f: GrayFrame)] = [
            (0, base), (1, base),                          // 首帧保存 t=0（也启动冷却基线）
            (5, c1), (6, c1),                              // t=5 冷却已过 → 触发，decisionT=6
            (7, c2), (8, c2),                              // 冷却 6..11 内 → 抑制
            (12, base), (13, c3), (14, c3),                // t=12 冷却已过 → 缓冲回存
        ]
        let actions = run(frames, params: p)
        let s = saves(actions)
        XCTAssertTrue(s.contains(5), "首个变化应保存")
        XCTAssertFalse(s.contains(7) || s.contains(8), "冷却期内的变化应被抑制")
        XCTAssertTrue(s.contains { $0 >= 12 }, "冷却期过后应恢复保存")
    }

    // MARK: 窗口缩放（画面变大变化）

    func testWindowResizeTriggers() {
        let base = baseFrame()
        // 模拟窗口缩放：内容区整体位移（大面积变化）
        var b = [UInt8](repeating: 240, count: 320 * 180)
        for r in 30..<(30 + 135) { for c in 40..<(40 + 240) { b[r * 320 + c] = base.bytes[(r - 10) * 320 + (c - 10)] } }
        let resized = GrayFrame(width: 320, height: 180, bytes: b)
        let frames: [(t: TimeInterval, f: GrayFrame)] = [
            (0, base), (1, base), (2, resized), (3, resized),
        ]
        let s = saves(run(frames))
        XCTAssertTrue(s.contains(2), "窗口缩放（大面积位移）应触发")
    }
}
