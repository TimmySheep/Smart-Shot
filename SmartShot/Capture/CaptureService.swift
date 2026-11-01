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
        public let width: Int          // 像素（Retina 感知）
        public let height: Int
        public let pointWidth: Int     // 点（用户可见尺寸）
        public let pointHeight: Int
        public let onScreen: Bool
        public let scWindow: SCWindow

        /// 过小的窗口多为工具条、浮层或辅助窗，通常不是想录的目标。
        public var looksAuxiliary: Bool { pointWidth < 320 || pointHeight < 240 }
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
            .map { w -> WindowInfo in
                let px = pixelSize(of: w)
                return WindowInfo(id: w.windowID,
                                  appBundleID: w.owningApplication?.bundleIdentifier,
                                  appName: w.owningApplication?.applicationName ?? "未知应用",
                                  windowTitle: w.title ?? "",
                                  width: px.width,
                                  height: px.height,
                                  pointWidth: Int(w.frame.width.rounded()),
                                  pointHeight: Int(w.frame.height.rounded()),
                                  onScreen: w.isOnScreen, scWindow: w)
            }
            // 主窗口在前：按可见面积降序，避免把工具条/浮层排在首位被误选。
            .sorted { ($0.pointWidth * $0.pointHeight) > ($1.pointWidth * $1.pointHeight) }
        return AvailableTargets(displays: displays, windows: windows)
    }

    /// 窗口的真实像素尺寸。
    ///
    /// 不能由 `frame × 2` 推算：`SCWindow.frame` 是点，缩放比例取决于该窗口所在显示器
    /// （内置 Retina 为 2×，外接非 Retina 为 1×，缩放分辨率也可能是非整数倍）。
    public static func pixelSize(of window: SCWindow) -> (width: Int, height: Int) {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale)
        let rect = filter.contentRect
        var w = Int((rect.width * scale).rounded())
        var h = Int((rect.height * scale).rounded())
        if w <= 0 || h <= 0 {
            // 极少数窗口 contrentRect 为空：退回点数（保底，不放大）
            w = Int(window.frame.width.rounded())
            h = Int(window.frame.height.rounded())
        }
        return (max(1, w), max(1, h))
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
///  - **尺寸取自实时窗口/显示器几何**（不信任持久化的旧目标尺寸，否则会把
///    2560×1440 的窗口压成几百像素，既糊又让检测阈值失真）；
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

    /// 上限保护：异常几何不应触发超大帧缓冲。
    private static let maxDimension = 8192

    /// 开始采集。
    /// - Returns: 实际使用的目标（含实时像素尺寸；窗口 ID 失效时可能是重新解析到的窗口）。
    @discardableResult
    public func start(target: CaptureTargetID, fps: Double) throws -> CaptureTargetID {
        stop()
        let content = try awaitish { try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) }
        let filter: SCContentFilter
        var resolved = target
        var pixelWidth = target.pixelWidth
        var pixelHeight = target.pixelHeight

        switch target.kind {
        case .display:
            guard let display = content.displays.first(where: { $0.displayID == target.id }) else {
                throw CaptureServiceError.contentUnavailable("显示器 \(target.id) 已不可用")
            }
            filter = SCContentFilter(display: display, excludingWindows: [])
            pixelWidth = display.width
            pixelHeight = display.height
            resolved.pixelWidth = pixelWidth
            resolved.pixelHeight = pixelHeight
        case .window:
            guard let window = Self.resolveWindow(for: target, in: content) else {
                throw CaptureServiceError.contentUnavailable(
                    "窗口 \(target.id) 已不可用或已关闭（应用：\(target.appName ?? "未知")）")
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
            let scale = CGFloat(filter.pointPixelScale)
            let rect = filter.contentRect
            pixelWidth = max(1, Int((rect.width * scale).rounded()))
            pixelHeight = max(1, Int((rect.height * scale).rounded()))
            resolved = CaptureTargetID(kind: .window, id: window.windowID,
                                       appBundleID: window.owningApplication?.bundleIdentifier ?? target.appBundleID,
                                       appName: window.owningApplication?.applicationName ?? target.appName,
                                       windowTitle: window.title ?? target.windowTitle,
                                       pixelWidth: pixelWidth, pixelHeight: pixelHeight)
        }

        let width = min(pixelWidth, Self.maxDimension)
        let height = min(pixelHeight, Self.maxDimension)

        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: Int32(max(1, Int(fps.rounded()))))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        // 光标会烧进截图与检测帧：鼠标移动会产生虚假变化，也不适合作为学习素材。
        config.showsCursor = false
        // 队列深度留出余量：会话层会尽快归还采集缓冲，但仍避免池被打满导致停摆。
        config.queueDepth = 8
        config.colorSpaceName = CGColorSpace.sRGB
        config.scalesToFit = false

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try stream.startCapture()
        self.stream = stream
        self.target = resolved
        self.captureSize = nil
        self.isRunning = true
        return resolved
    }

    public func stop() {
        guard let stream else { return }
        try? stream.stopCapture()
        self.stream = nil
        self.target = nil
        self.isRunning = false
        self.captureSize = nil
    }

    /// 解析目标窗口：精确 ID 优先；ID 会在应用重启/窗口重建后变化，
    /// 因此退回到「同应用 + 同标题」，再退回到「同应用最大窗口」。
    static func resolveWindow(for target: CaptureTargetID, in content: SCShareableContent) -> SCWindow? {
        if let exact = content.windows.first(where: { $0.windowID == target.id }) {
            return exact
        }
        let candidatePool = content.windows.filter { $0.isOnScreen && $0.windowLayer == 0 }
        if let bundle = target.appBundleID {
            let sameApp = candidatePool.filter { $0.owningApplication?.bundleIdentifier == bundle }
            if let title = target.windowTitle, !title.isEmpty,
               let byTitle = sameApp.first(where: { ($0.title ?? "") == title }) {
                return byTitle
            }
            if let largest = sameApp.max(by: {
                ($0.frame.width * $0.frame.height) < ($1.frame.width * $1.frame.height)
            }) {
                return largest
            }
        }
        if let name = target.appName, !name.isEmpty {
            return candidatePool
                .filter { $0.owningApplication?.applicationName == name }
                .max(by: { ($0.frame.width * $0.frame.height) < ($1.frame.width * $1.frame.height) })
        }
        return nil
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
            return resolveWindow(for: target, in: content) != nil
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
