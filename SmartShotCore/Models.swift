import Foundation

/// 截图模式。
public enum CaptureMode: String, Codable, CaseIterable, Sendable {
    case timed      // 定时截图（基准方案，独立工作）
    case smart     // 智能检测 + 定时保底
}

/// 触发原因。equivalence-tested 的取值保持稳定（replay 对比依赖）。
public enum TriggerReason: String, Codable, CaseIterable, Sendable {
    case firstFrame      // 首帧
    case smartChange     // 智能触发（缓冲回存）
    case blipRescue      // 瞬变抢救
    case heartbeat       // 定时保底
    case timed           // 定时模式
    case manual          // 手动保存
    case dynamicStart    // 连续动态画面开始
    case dynamicSample   // 连续动态画面定时采样
    case dynamicEnd      // 连续动态画面结束
    case fallbackResave  // 缓冲帧不可用时的就近回退保存
}

/// 监控目标（核心层只描述，不依赖 ScreenCaptureKit 类型）。
public enum CaptureTargetKind: String, Codable, Sendable {
    case display
    case window
}

public struct CaptureTargetID: Codable, Hashable, Sendable {
    public var kind: CaptureTargetKind
    /// display: CGDirectDisplayID；window: CGWindowID。
    public var id: UInt32
    public var appBundleID: String?
    public var appName: String?
    public var windowTitle: String?
    public var pixelWidth: Int
    public var pixelHeight: Int

    public init(kind: CaptureTargetKind, id: UInt32, appBundleID: String? = nil,
                appName: String? = nil, windowTitle: String? = nil,
                pixelWidth: Int, pixelHeight: Int) {
        self.kind = kind
        self.id = id
        self.appBundleID = appBundleID
        self.appName = appName
        self.windowTitle = windowTitle
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    public var displayName: String {
        switch kind {
        case .display: return "显示器 \(pixelWidth)×\(pixelHeight)"
        case .window:
            let app = appName ?? appBundleID ?? "未知应用"
            let title = windowTitle ?? ""
            return title.isEmpty ? app : "\(app) — \(title)"
        }
    }
}

/// 单张截图的元数据（写入 JSONL 事件流）。
public struct ShotMetadata: Codable, Sendable {
    public var filename: String
    public var relativePath: String
    public var captureFrameTimestamp: TimeInterval   // 实际保存帧的采集时间戳
    public var decisionTimestamp: TimeInterval       // 触发决策时间戳
    public var latencyMillis: Int                   // decision - frame
    public var width: Int
    public var height: Int
    public var reason: TriggerReason
    public var reasonDetail: String
    public var sha256: String
    public var byteCount: Int
    public var encodeMillis: Int
    public var writeMillis: Int
    public var target: CaptureTargetID
    public var parameters: DetectionParameters
    public var appVersion: String

    public init(filename: String, relativePath: String, captureFrameTimestamp: TimeInterval,
                decisionTimestamp: TimeInterval, latencyMillis: Int, width: Int, height: Int,
                reason: TriggerReason, reasonDetail: String, sha256: String, byteCount: Int,
                encodeMillis: Int, writeMillis: Int, target: CaptureTargetID,
                parameters: DetectionParameters, appVersion: String) {
        self.filename = filename
        self.relativePath = relativePath
        self.captureFrameTimestamp = captureFrameTimestamp
        self.decisionTimestamp = decisionTimestamp
        self.latencyMillis = latencyMillis
        self.width = width
        self.height = height
        self.reason = reason
        self.reasonDetail = reasonDetail
        self.sha256 = sha256
        self.byteCount = byteCount
        self.encodeMillis = encodeMillis
        self.writeMillis = writeMillis
        self.target = target
        self.parameters = parameters
        self.appVersion = appVersion
    }
}

/// JSONL 事件流中的通用事件封装。
public struct JournalEvent: Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case shot            // 已保存截图
        case suppressed      // 被冷却/限频/动态策略抑制的候选（聚合）
        case discardedPending // 持续性未满足而丢弃的待定帧
        case permission      // 权限异常
        case runtime         // 运行异常/恢复
        case targetLost      // 目标丢失
        case perf            // 性能采样
        case sessionStart
        case sessionStop
        case modeChange
        case bufferOverflow  // 缓冲区溢出导致的帧淘汰/回退
        case diskFull
    }

    public var kind: Kind
    public var timestamp: TimeInterval
    public var message: String
    public var shot: ShotMetadata?
    public var data: [String: String]?

    public init(kind: Kind, timestamp: TimeInterval, message: String,
                shot: ShotMetadata? = nil, data: [String: String]? = nil) {
        self.kind = kind
        self.timestamp = timestamp
        self.message = message
        self.shot = shot
        self.data = data
    }
}
