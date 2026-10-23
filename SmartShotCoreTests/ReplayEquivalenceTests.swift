import XCTest
@testable import SmartShotCore

/// 回放等价性测试：把研究的 .gray 灰度流按帧喂给 Swift CapturePolicy，
/// 与 Python p4_detector.py 的输出逐个时间戳比对。
///
/// 前置条件（不满足则整体跳过，不视为失败）：
///  - 研究目录存在：`.../智能截图视频级研究_20261023/raw/{20,13}_1fps_320x180.gray`
///  - Python 参考输出已生成：`testdata/ref/{20,13}_{F_buffer,C_region}.json`
///
/// 该测试验证的是"Swift 移植与研究参考实现逐帧等价"，
/// 不代表 App 实际运行（真实采集、转换、写盘）等同于离线结果。
final class ReplayEquivalenceTests: XCTestCase {

    static let researchDir = URL(fileURLWithPath:
        "/Users/TimmySheep/AWS/sMDP/work/课程笔记工作流/优化方向/智能截图视频级研究_20261023")
    static let repoDir = URL(fileURLWithPath: "/Users/TimmySheep/AWS/smartshot")

    private struct RefOutput {
        let savedTimes: [Double]
        let frames: Int
        let stage1Hits: Int
    }

    private func loadRef(_ name: String) throws -> RefOutput {
        let url = Self.repoDir.appendingPathComponent("testdata/ref/\(name).json")
        let data = try Data(contentsOf: url)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let times = try XCTUnwrap(obj["saved_times"] as? [Double])
        let frames = obj["frames"] as? Int ?? 0
        let hits = obj["stage1_hits"] as? Int ?? 0
        return RefOutput(savedTimes: times, frames: frames, stage1Hits: hits)
    }

    private func replay(grayPath: String, params: DetectionParameters) throws -> (saved: [TimeInterval], policy: CapturePolicy) {
        let frames = try GrayConverter.loadRawGrayFile(
            url: URL(fileURLWithPath: grayPath), width: 320, height: 180)
        let policy = CapturePolicy(params: params)
        var saved: [TimeInterval] = []
        for (k, frame) in frames.enumerated() {
            for action in policy.step(t: TimeInterval(k), frame: frame) {
                if case .save(let t, _, _) = action { saved.append(t) }
            }
        }
        return (saved, policy)
    }

    /// F 缓冲检测器（研究主推配置）：20.mov。
    func testFBufferVideo20Equivalence() throws {
        let gray = Self.researchDir.appendingPathComponent("raw/20_1fps_320x180.gray").path
        guard FileManager.default.fileExists(atPath: gray) else {
            throw XCTSkip("研究灰度流不存在，跳过：\(gray)")
        }
        let ref = try loadRef("20_F_buffer")
        var p = DetectionParameters.researchFrozen
        p.blipRescue = true
        p.heartbeatSeconds = 60
        let (saved, policy) = try replay(grayPath: gray, params: p)

        XCTAssertEqual(policy.framesSeen, ref.frames, "帧数不一致")
        XCTAssertEqual(policy.stage1Hits, ref.stage1Hits, "一级命中数不一致（XOR 预筛语义偏移）")
        XCTAssertEqual(saved, ref.savedTimes,
                       "保存时间戳序列与 Python 参考不一致（检测器语义偏移）")
    }

    /// F 缓冲检测器：13.mov（冻结阈值泛化段）。
    func testFBufferVideo13Equivalence() throws {
        let gray = Self.researchDir.appendingPathComponent("raw/13_1fps_320x180.gray").path
        guard FileManager.default.fileExists(atPath: gray) else {
            throw XCTSkip("研究灰度流不存在，跳过")
        }
        let ref = try loadRef("13_F_buffer")
        var p = DetectionParameters.researchFrozen
        p.blipRescue = true
        p.heartbeatSeconds = 60
        let (saved, policy) = try replay(grayPath: gray, params: p)

        XCTAssertEqual(policy.framesSeen, ref.frames)
        XCTAssertEqual(policy.stage1Hits, ref.stage1Hits)
        XCTAssertEqual(saved, ref.savedTimes)
    }

    /// C 区域检测器（无缓冲）：20.mov。
    func testCRegionVideo20Equivalence() throws {
        let gray = Self.researchDir.appendingPathComponent("raw/20_1fps_320x180.gray").path
        guard FileManager.default.fileExists(atPath: gray) else {
            throw XCTSkip("研究灰度流不存在，跳过")
        }
        let ref = try loadRef("20_C_region")
        var p = DetectionParameters.researchFrozen
        p.persistFrames = 1   // C_region 无持续性确认
        p.blipRescue = false
        p.heartbeatSeconds = 0  // 参考 C_region 无心跳（<=0 = 关闭）
        p.pagePixels = Int.max  // C_region 只有分区峰值触发，无页面级立即保存
        let (saved, policy) = try replay(grayPath: gray, params: p)

        XCTAssertEqual(policy.framesSeen, ref.frames)
        XCTAssertEqual(policy.stage1Hits, ref.stage1Hits)
        XCTAssertEqual(saved, ref.savedTimes)
    }

    /// 因果性检查：截断到第 N 帧重放，前缀保存序列必须与全量重放一致。
    /// （证明检测器不使用未来帧决定过去的截图。）
    func testCausalityPrefixStability() throws {
        let gray = Self.researchDir.appendingPathComponent("raw/20_1fps_320x180.gray").path
        guard FileManager.default.fileExists(atPath: gray) else {
            throw XCTSkip("研究灰度流不存在，跳过")
        }
        let allFrames = try GrayConverter.loadRawGrayFile(
            url: URL(fileURLWithPath: gray), width: 320, height: 180)
        let cutoff = min(1500, allFrames.count)

        var p = DetectionParameters.researchFrozen
        p.blipRescue = true
        p.heartbeatSeconds = 60

        // 全量
        let fullPolicy = CapturePolicy(params: p)
        var fullSaved: [TimeInterval] = []
        for (k, f) in allFrames.enumerated() {
            for a in fullPolicy.step(t: TimeInterval(k), frame: f) {
                if case .save(let t, _, _) = a { fullSaved.append(t) }
            }
        }
        // 截断
        let cutPolicy = CapturePolicy(params: p)
        var cutSaved: [TimeInterval] = []
        for k in 0..<cutoff {
            for a in cutPolicy.step(t: TimeInterval(k), frame: allFrames[k]) {
                if case .save(let t, _, _) = a { cutSaved.append(t) }
            }
        }
        let expectedPrefix = fullSaved.filter { $0 < TimeInterval(cutoff) }
        XCTAssertEqual(cutSaved, expectedPrefix,
                       "因果性破坏：截断重放的保存序列与全量重放前缀不一致")
    }
}
