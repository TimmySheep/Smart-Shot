import Foundation

/// 检测与策略参数。
///
/// 默认值来自《智能截图视频级研究_20261023》冻结配置（20.mov 调参段选定、
/// 13.mov 验证段泛化）：C/F 检测器 prefilter=8000 位、区域峰值=20 像素、
/// 页面像素=3000、persist=2、心跳=60s、blip_rescue=true。
///
/// 注意：这些数字的成立前提是 **320×180 灰度输入、像素阈值 25、8×4 分区、
/// 排除菜单栏(0..<4 行)与 Dock(171..<180 行)**，且检测帧率为 1fps。
/// 研究同时表明 2/5fps 未重新校准会恶化精度，因此检测帧率默认 1fps，
/// 更高帧率在 UI 中标注为实验性。
public struct DetectionParameters: Codable, Equatable, Sendable {
    // 两级检测（对应 p4_detector.py 的 cheap_bits + region_counts）
    public var prefilterBits: Int      // 第一级整帧 XOR 位数阈值
    public var regionPeak: Int         // 第二级任一分区变化像素峰值阈值
    public var pagePixels: Int         // 总变化像素超过此值视为页面级变化
    public var pixelThreshold: Int     // 单像素灰度差阈值（25）
    public var gridColumns: Int        // 分区列数（8）
    public var gridRows: Int           // 分区行数（4）
    public var excludeTopRows: Int     // 排除顶部行（菜单栏，4）
    public var excludeBottomRows: Int  // 排除底部行（Dock，9 → 180-171）

    // 策略
    public var persistFrames: Int      // 持续性确认帧数
    public var blipRescue: Bool        // 瞬变抢救
    public var heartbeatSeconds: TimeInterval  // 定时保底间隔
    public var cooldownSeconds: TimeInterval   // 触发冷却（0 = 研究验证配置）
    public var detectionFPS: Double    // 检测帧率

    // 连续动态画面（实验性，研究未覆盖）
    public var dynamicEnabled: Bool
    public var dynamicEnterFrames: Int          // 连续超阈值帧数 → 进入动态模式
    public var dynamicSampleSeconds: TimeInterval // 动态模式下采样间隔
    public var dynamicExitQuietFrames: Int      // 连续安静帧数 → 退出动态模式

    // 定时模式
    public var timedIntervalSeconds: TimeInterval

    // 分析分辨率（研究基准 320×180；修改会使冻结阈值失效）
    public var analysisWidth: Int
    public var analysisHeight: Int

    public init(prefilterBits: Int = 8000, regionPeak: Int = 20, pagePixels: Int = 3000,
                pixelThreshold: Int = 25, gridColumns: Int = 8, gridRows: Int = 4,
                excludeTopRows: Int = 4, excludeBottomRows: Int = 9,
                persistFrames: Int = 2, blipRescue: Bool = true,
                heartbeatSeconds: TimeInterval = 10, cooldownSeconds: TimeInterval = 0,
                detectionFPS: Double = 1,
                dynamicEnabled: Bool = true, dynamicEnterFrames: Int = 6,
                dynamicSampleSeconds: TimeInterval = 15, dynamicExitQuietFrames: Int = 5,
                timedIntervalSeconds: TimeInterval = 30,
                analysisWidth: Int = 320, analysisHeight: Int = 180) {
        self.prefilterBits = prefilterBits
        self.regionPeak = regionPeak
        self.pagePixels = pagePixels
        self.pixelThreshold = pixelThreshold
        self.gridColumns = gridColumns
        self.gridRows = gridRows
        self.excludeTopRows = excludeTopRows
        self.excludeBottomRows = excludeBottomRows
        self.persistFrames = persistFrames
        self.blipRescue = blipRescue
        self.heartbeatSeconds = heartbeatSeconds
        self.cooldownSeconds = cooldownSeconds
        self.detectionFPS = detectionFPS
        self.dynamicEnabled = dynamicEnabled
        self.dynamicEnterFrames = dynamicEnterFrames
        self.dynamicSampleSeconds = dynamicSampleSeconds
        self.dynamicExitQuietFrames = dynamicExitQuietFrames
        self.timedIntervalSeconds = timedIntervalSeconds
        self.analysisWidth = analysisWidth
        self.analysisHeight = analysisHeight
    }

    /// 研究冻结配置（F 缓冲 + 瞬变抢救），与 testdata/ref 中的 Python 参考一致。
    public static let researchFrozen = DetectionParameters(
        prefilterBits: 8000, regionPeak: 20, pagePixels: 3000,
        persistFrames: 2, blipRescue: true,
        heartbeatSeconds: 60, cooldownSeconds: 0, detectionFPS: 1,
        dynamicEnabled: false)

    /// App 默认：研究阈值 + 保守 10s 保底（研究建议保留 10 秒故障兜底）。
    public static let appDefault = DetectionParameters()

    public var analysisFrameBytes: Int { analysisWidth * analysisHeight }
}
