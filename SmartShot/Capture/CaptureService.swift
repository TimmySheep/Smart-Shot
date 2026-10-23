import SmartShotCore
import Foundation
import ScreenCaptureKit
import CoreGraphics

public enum CaptureServiceError: Error, LocalizedError {
    case screenRecordingDenied
    case contentUnavailable(String)
    case streamFailed(String)

    public var errorDescription: String? {
        switch self {
        case .screenRecordingDenied:
            return "屏幕录制权限未授予。请在“系统设置 → 隐私与安全性 → 屏幕录制”中允许 Smart Shot。"
        case .contentUnavailable(let m): return "无法获取采集目标：\(m)"
        case .streamFailed(let m): return "采集流异常：\(m)"
        }
    }
}

/// 可用目标（显示器/窗口）快照。
public struct AvailableTargets: Sendable {
    public struct DisplayInfo: Identifiable, Sendable {
        public let id: UInt32          // CGDirectDisplayID
        public let name: String
        public let width: Int          // 像素
        public let height: Int
        public let sCDisplay: SCDisplay
    }
    public struct WindowInfo: Identifiable, Sendable {
        public let id: UInt32          // CGWindowID
        public let appBundleID: String?
        public let appName: String
        public let windowTitle: String
        public let width: Int
        public let height: Int
        public let onScreen: Bool
        public let scWindow: SCWindow
    }
    public var displays: [DisplayInfo]
    public var windows: [WindowInfo]

    @MainActor
    public static func fetch(excludeOwnWindows: Bool = true) async throws -> AvailableTargets {
        guard CGPreflightScreenCaptureAccess() else {
            throw CaptureServiceError.screenRecordingDenied
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false,
                                                                           onScreenWindowsOnly: true)
        let displays = content.displays.map { d in
            DisplayInfo(id: d.displayID, name: "显示器 \(d.displayID)", width: d.width,
                        height: d.height, sCDisplay: d)
        }
        let windows = content.windows
            .filter { $0.isOnScreen && $0.windowLayer == 0 }
            .filter { w in
                guard excludeOwnWindows else { return true }
                return Bundle.main.bundleIdentifier == nil
                    || w.owningApplication?.bundleIdentifier != Bundle.main.bundleIdentifier
            }
            .map { w in
                WindowInfo(id: w.windowID,
                           appBundleID: w.owningApplication?.bundleIdentifier,
                           appName: w.owningApplication?.applicationName ?? "未知应用",
                           windowTitle: w.title ?? "",
                           width: Int(w.frame.width * 2),   // 粗略 Retina 像素（仅显示用）
                           height: Int(w.frame.height * 2),
                           onScreen: w.isOnScreen, scWindow: w)
            }
        return AvailableTargets(displays: displays, windows: windows)
    }
}

/// 屏幕录制权限管理。
public enum ScreenPermission {
    public static var isGranted: Bool { CGPreflightScreenCaptureAccess() }

    @discardableResult
    public static func request() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    public static let systemSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
}

/// ScreenCaptureKit 采集服务：管理流生命周期、异常恢复。
///
/// 采集策略：
///  - 输出 kCVPixelFormatType_32BGRA，最小帧间隔由 detectionFPS 决定；
///  - 每帧回调交给 onFrame（在串行 queue 上），由上层做灰度化/检测/入缓冲；
///  - 流错误（含权限被撤销）通过 onError 上报，上层决定重试或停止。
public final class CaptureService: NSObject, SCStreamOutput, SCStreamDelegate {
    public typealias FrameHandler = (CVPixelBuffer, TimeInterval) -> Void
    public typealias ErrorHandler = (Error) -> Void

    private let queue = DispatchQueue(label: "com.smartshot.capture", qos: .userInitiated)
    private var stream: SCStream?
    private var target: CaptureTargetID?
    public var onFrame: FrameHandler?
    public var onError: ErrorHandler?
    public private(set) var isRunning = false

    /// 当前会话实际采集的像素尺寸（首帧时填充，用于元数据）。
    public private(set) var captureSize: (width: Int, height: Int)?

    public func start(target: CaptureTargetID, fps: Double) throws {
        stop()
        let content = try awaitish { try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) }
        let filter: SCContentFilter
        switch target.kind {
        case .display:
            guard let display = content.displays.first(where: { $0.displayID == target.id }) else {
                throw CaptureServiceError.contentUnavailable("显示器 \(target.id) 已不可用")
            }
            filter = SCContentFilter(display: display, excludingWindows: [])
        case .window:
            guard let window = content.windows.first(where: { $0.windowID == target.id }) else {
                throw CaptureServiceError.contentUnavailable("窗口 \(target.id) 已不可用或已关闭")
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
        }

        let config = SCStreamConfiguration()
        config.width = target.pixelWidth
        config.height = target.pixelHeight
        config.minimumFrameInterval = CMTime(value: 1, timescale: Int32(max(1, Int(fps.rounded()))))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true
        config.queueDepth = 6
        config.colorSpaceName = CGColorSpace.sRGB

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try stream.startCapture()
        self.stream = stream
        self.target = target
        self.captureSize = nil
        self.isRunning = true
    }

    public func stop() {
        guard let stream else { return }
        try? stream.stopCapture()
        self.stream = nil
        self.target = nil
        self.isRunning = false
        self.captureSize = nil
    }

    /// SCStreamOutput
    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                       of type: SCStreamOutputType) {
        guard type == .screen,
              let pixelBuffer = sampleBuffer.imageBuffer else { return }
        if captureSize == nil {
            captureSize = (CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer))
        }
        let ts = CMTimeGetSeconds(sampleBuffer.presentationTimeStamp)
        onFrame?(pixelBuffer, ts)
    }

    /// SCStreamDelegate
    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        isRunning = false
        onError?(error)
    }

    /// 目标窗口是否仍存在（供运行中巡检）。
    public static func targetStillExists(_ target: CaptureTargetID) async -> Bool {
        guard CGPreflightScreenCaptureAccess() else { return false }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else {
            return false
        }
        switch target.kind {
        case .display:
            return content.displays.contains { $0.displayID == target.id }
        case .window:
            return content.windows.contains { $0.windowID == target.id && $0.isOnScreen }
        }
    }

    // 简易同步等待（start 为同步 API，内部只做一次内容查询）
    private func awaitish<T>(_ op: @escaping () async throws -> T) throws -> T {
        // 在 Obj-C 运行时外用信号量同步；仅在用户点击“开始”时短暂阻塞主线程
        var result: Result<T, Error>!
        let sem = DispatchSemaphore(value: 0)
        Task {
            do { result = .success(try await op()) }
            catch { result = .failure(error) }
            sem.signal()
        }
        sem.wait()
        return try result.get()
    }
}
