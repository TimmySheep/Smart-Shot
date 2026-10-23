import SmartShotCore
import Foundation
import SwiftUI
import ServiceManagement

/// 用户设置（UserDefaults 持久化）。
public final class AppSettings: ObservableObject {
    public static let shared = AppSettings()

    private let d = UserDefaults.standard

    private enum K {
        static let launchAtLogin = "launchAtLogin"
        static let keepRunningOnClose = "keepRunningOnClose"
        static let showMenuBar = "showMenuBar"
        static let outputDirectory = "outputDirectory"
        static let imageFormat = "imageFormat"
        static let organizeByDate = "organizeByDate"
        static let minimumFreeGB = "minimumFreeGB"
        static let stopOnLowDisk = "stopOnLowDisk"
        static let mode = "mode"
        static let heartbeatSeconds = "heartbeatSeconds"
        static let timedIntervalSeconds = "timedIntervalSeconds"
        static let detectionFPS = "detectionFPS"
        static let cooldownSeconds = "cooldownSeconds"
        static let sensitivity = "sensitivity"
        static let dynamicEnabled = "dynamicEnabled"
        static let dynamicSampleSeconds = "dynamicSampleSeconds"
        static let persistFrames = "persistFrames"
        static let blipRescue = "blipRescue"
        static let prefilterBits = "prefilterBits"
        static let regionPeak = "regionPeak"
        static let pagePixels = "pagePixels"
        static let targetKind = "targetKind"
        static let targetID = "targetID"
        static let targetApp = "targetApp"
        static let targetAppName = "targetAppName"
        static let targetWindowTitle = "targetWindowTitle"
        static let targetW = "targetW"
        static let targetH = "targetH"
    }

    @Published public var launchAtLogin: Bool { didSet { d.set(launchAtLogin, forKey: K.launchAtLogin); applyLogin() } }
    @Published public var keepRunningOnClose: Bool { didSet { d.set(keepRunningOnClose, forKey: K.keepRunningOnClose) } }
    @Published public var showMenuBar: Bool { didSet { d.set(showMenuBar, forKey: K.showMenuBar) } }
    @Published public var outputDirectory: URL { didSet { d.set(outputDirectory.path, forKey: K.outputDirectory) } }
    @Published public var imageFormat: CaptureWriter.ImageFormat { didSet { d.set(imageFormat.rawValue, forKey: K.imageFormat) } }
    @Published public var organizeByDate: Bool { didSet { d.set(organizeByDate, forKey: K.organizeByDate) } }
    @Published public var minimumFreeGB: Double { didSet { d.set(minimumFreeGB, forKey: K.minimumFreeGB) } }
    @Published public var stopOnLowDisk: Bool { didSet { d.set(stopOnLowDisk, forKey: K.stopOnLowDisk) } }

    @Published public var mode: CaptureMode { didSet { d.set(mode.rawValue, forKey: K.mode) } }
    @Published public var heartbeatSeconds: Double { didSet { d.set(heartbeatSeconds, forKey: K.heartbeatSeconds) } }
    @Published public var timedIntervalSeconds: Double { didSet { d.set(timedIntervalSeconds, forKey: K.timedIntervalSeconds) } }
    @Published public var detectionFPS: Double { didSet { d.set(detectionFPS, forKey: K.detectionFPS) } }
    @Published public var cooldownSeconds: Double { didSet { d.set(cooldownSeconds, forKey: K.cooldownSeconds) } }
    /// 灵敏度预设：0=保守 1=标准（研究冻结） 2=敏感
    @Published public var sensitivity: Int { didSet { d.set(sensitivity, forKey: K.sensitivity) } }
    @Published public var dynamicEnabled: Bool { didSet { d.set(dynamicEnabled, forKey: K.dynamicEnabled) } }
    @Published public var dynamicSampleSeconds: Double { didSet { d.set(dynamicSampleSeconds, forKey: K.dynamicSampleSeconds) } }

    // 高级（默认跟研究冻结值；普通用户不动）
    @Published public var persistFrames: Int { didSet { d.set(persistFrames, forKey: K.persistFrames) } }
    @Published public var blipRescue: Bool { didSet { d.set(blipRescue, forKey: K.blipRescue) } }
    @Published public var prefilterBits: Int { didSet { d.set(prefilterBits, forKey: K.prefilterBits) } }
    @Published public var regionPeak: Int { didSet { d.set(regionPeak, forKey: K.regionPeak) } }
    @Published public var pagePixels: Int { didSet { d.set(pagePixels, forKey: K.pagePixels) } }

    @Published public var savedTarget: CaptureTargetID?

    private init() {
        launchAtLogin = d.object(forKey: K.launchAtLogin) as? Bool ?? false
        keepRunningOnClose = d.object(forKey: K.keepRunningOnClose) as? Bool ?? true
        showMenuBar = d.object(forKey: K.showMenuBar) as? Bool ?? true
        let defaultDir = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        outputDirectory = d.string(forKey: K.outputDirectory).flatMap(URL.init(fileURLWithPath:)) ?? defaultDir
        imageFormat = d.string(forKey: K.imageFormat).flatMap(CaptureWriter.ImageFormat.init(rawValue:)) ?? .png
        organizeByDate = d.object(forKey: K.organizeByDate) as? Bool ?? true
        minimumFreeGB = d.object(forKey: K.minimumFreeGB) as? Double ?? 2
        stopOnLowDisk = d.object(forKey: K.stopOnLowDisk) as? Bool ?? true
        mode = d.string(forKey: K.mode).flatMap(CaptureMode.init(rawValue:)) ?? .smart
        heartbeatSeconds = d.object(forKey: K.heartbeatSeconds) as? Double ?? 10
        timedIntervalSeconds = d.object(forKey: K.timedIntervalSeconds) as? Double ?? 30
        detectionFPS = d.object(forKey: K.detectionFPS) as? Double ?? 1
        cooldownSeconds = d.object(forKey: K.cooldownSeconds) as? Double ?? 2
        sensitivity = d.object(forKey: K.sensitivity) as? Int ?? 1
        dynamicEnabled = d.object(forKey: K.dynamicEnabled) as? Bool ?? true
        dynamicSampleSeconds = d.object(forKey: K.dynamicSampleSeconds) as? Double ?? 15
        persistFrames = d.object(forKey: K.persistFrames) as? Int ?? 2
        blipRescue = d.object(forKey: K.blipRescue) as? Bool ?? true
        prefilterBits = d.object(forKey: K.prefilterBits) as? Int ?? 8000
        regionPeak = d.object(forKey: K.regionPeak) as? Int ?? 20
        pagePixels = d.object(forKey: K.pagePixels) as? Int ?? 3000

        if let kind = d.string(forKey: K.targetKind), let idv = d.object(forKey: K.targetID) as? UInt32,
           let kindV = CaptureTargetKind(rawValue: kind) {
            savedTarget = CaptureTargetID(kind: kindV, id: idv,
                                          appBundleID: d.string(forKey: K.targetApp),
                                          appName: d.string(forKey: K.targetAppName),
                                          windowTitle: d.string(forKey: K.targetWindowTitle),
                                          pixelWidth: d.object(forKey: K.targetW) as? Int ?? 2560,
                                          pixelHeight: d.object(forKey: K.targetH) as? Int ?? 1440)
        } else {
            savedTarget = nil
        }
    }

    public func saveTarget(_ t: CaptureTargetID?) {
        savedTarget = t
        d.set(t?.kind.rawValue, forKey: K.targetKind)
        d.set(t?.id, forKey: K.targetID)
        d.set(t?.appBundleID, forKey: K.targetApp)
        d.set(t?.appName, forKey: K.targetAppName)
        d.set(t?.windowTitle, forKey: K.targetWindowTitle)
        d.set(t?.pixelWidth, forKey: K.targetW)
        d.set(t?.pixelHeight, forKey: K.targetH)
    }

    /// 按灵敏度预设/高级覆盖合成检测参数。
    public func makeParameters() -> DetectionParameters {
        var p = DetectionParameters()
        switch sensitivity {
        case 0:  p.prefilterBits = 15000; p.regionPeak = 60
        case 2:  p.prefilterBits = 5000;  p.regionPeak = 12; p.pagePixels = 1500
        default: p.prefilterBits = 8000;  p.regionPeak = 20; p.pagePixels = 3000
        }
        // 高级面板覆盖（若用户改过）
        p.prefilterBits = prefilterBits
        p.regionPeak = regionPeak
        p.pagePixels = pagePixels
        p.persistFrames = persistFrames
        p.blipRescue = blipRescue
        p.heartbeatSeconds = heartbeatSeconds
        p.timedIntervalSeconds = timedIntervalSeconds
        p.detectionFPS = detectionFPS
        p.cooldownSeconds = cooldownSeconds
        p.dynamicEnabled = dynamicEnabled
        p.dynamicSampleSeconds = dynamicSampleSeconds
        return p
    }

    public func makeWriter() -> CaptureWriter {
        CaptureWriter(baseDirectory: outputDirectory, format: imageFormat,
                      organizeByDate: organizeByDate,
                      minimumFreeBytes: Int64(minimumFreeGB * 1024 * 1024 * 1024),
                      stopOnLowDisk: stopOnLowDisk,
                      appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0")
    }

    public func resetToDefaults() {
        let defaultDir = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        launchAtLogin = false
        keepRunningOnClose = true
        showMenuBar = true
        outputDirectory = defaultDir
        imageFormat = .png
        organizeByDate = true
        minimumFreeGB = 2
        stopOnLowDisk = true
        mode = .smart
        heartbeatSeconds = 10
        timedIntervalSeconds = 30
        detectionFPS = 1
        cooldownSeconds = 2
        sensitivity = 1
        dynamicEnabled = true
        dynamicSampleSeconds = 15
        persistFrames = 2
        blipRescue = true
        prefilterBits = 8000
        regionPeak = 20
        pagePixels = 3000
        NotificationCenter.default.post(name: .smartShotSettingsReset, object: nil)
    }

    private func applyLogin() {
        if #available(macOS 13.0, *) {
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                // 登录项失败不致命
                fputs("login item: \(error)\n", stderr)
            }
        }
    }
}

public extension Notification.Name {
    static let smartShotSettingsReset = Notification.Name("smartShotSettingsReset")
}
