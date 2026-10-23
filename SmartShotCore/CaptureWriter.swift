import Foundation
import CoreGraphics
import CoreVideo
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

public enum CaptureWriterError: Error, LocalizedError {
    case encodeFailed
    case createDirectoryFailed(String)
    case writeFailed(String)
    case diskSpaceLow(availableBytes: Int64)

    public var errorDescription: String? {
        switch self {
        case .encodeFailed: return "图像编码失败"
        case .createDirectoryFailed(let p): return "无法创建目录：\(p)"
        case .writeFailed(let m): return "写入失败：\(m)"
        case .diskSpaceLow(let b): return "磁盘可用空间不足（\(b / 1024 / 1024) MB）"
        }
    }
}

/// 截图写入器：PNG/JPEG 编码、唯一文件名、原子写入、SHA-256、元数据。
///
/// 安全约束（任务书 §3.7）：只写入用户指定目录下 `SmartShot/` 前缀路径，
/// 不修改、覆盖或删除其他软件的文件；重名时追加序号而非覆盖。
public final class CaptureWriter {
    public enum ImageFormat: String, Codable, CaseIterable, Sendable {
        case png, jpeg
        var utType: UTType { self == .png ? .png : .jpeg }
        var pathExtension: String { rawValue }
        var cgIdentifier: CFString {
            self == .png ? UTType.png.identifier as CFString : UTType.jpeg.identifier as CFString
        }
    }

    public struct WriteOutcome {
        public let metadata: ShotMetadata
        public let skipped: Bool     // 磁盘空间策略导致跳过
    }

    public let baseDirectory: URL
    public let format: ImageFormat
    public let jpegQuality: Double
    public let organizeByDate: Bool
    public let minimumFreeBytes: Int64       // 低于此值触发磁盘策略
    public let stopOnLowDisk: Bool           // true: 抛错让会话停止；false: 跳过本张并记账
    public let appVersion: String

    public init(baseDirectory: URL, format: ImageFormat = .png, jpegQuality: Double = 0.92,
                organizeByDate: Bool = true, minimumFreeBytes: Int64 = 2 * 1024 * 1024 * 1024,
                stopOnLowDisk: Bool = true, appVersion: String = "0.1.0") {
        self.baseDirectory = baseDirectory
        self.format = format
        self.jpegQuality = jpegQuality
        self.organizeByDate = organizeByDate
        self.minimumFreeBytes = minimumFreeBytes
        self.stopOnLowDisk = stopOnLowDisk
        self.appVersion = appVersion
    }

    /// SmartShot 子目录（永不指向用户目录之外）。
    public var smartShotRoot: URL {
        baseDirectory.appendingPathComponent("SmartShot", isDirectory: true)
    }

    /// 保存一帧高分辨率像素缓冲。
    /// - Returns: 元数据；若因磁盘策略跳过则返回 nil（stopOnLowDisk=false 时）。
    public func save(pixelBuffer: CVPixelBuffer,
                     frameTimestamp: TimeInterval,
                     decisionTimestamp: TimeInterval,
                     reason: TriggerReason,
                     reasonDetail: String,
                     target: CaptureTargetID,
                     parameters: DetectionParameters) throws -> WriteOutcome? {
        // 磁盘空间检查
        let values = try? baseDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let avail = values?.volumeAvailableCapacityForImportantUsage, avail < minimumFreeBytes {
            if stopOnLowDisk {
                throw CaptureWriterError.diskSpaceLow(availableBytes: avail)
            }
            return nil   // 跳过，调用方记账
        }

        let now = Date()
        let dir = organizeByDate
            ? smartShotRoot.appendingPathComponent(Self.dayString(now), isDirectory: true)
            : smartShotRoot
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let encodeStart = DispatchTime.now()
        let cgImage = Self.makeCGImage(from: pixelBuffer)
        guard let cgImage else { throw CaptureWriterError.encodeFailed }
        let width = cgImage.width, height = cgImage.height

        let data = try Self.encode(cgImage: cgImage, format: format, quality: jpegQuality)
        let encodeMillis = Int(DispatchTime.now().uptimeNanoseconds - encodeStart.uptimeNanoseconds) / 1_000_000

        // 唯一文件名（时间戳精确到毫秒 + 触发原因；冲突追加序号）
        let filename = uniqueFilename(in: dir, base: Self.filenameBase(now: now, reason: reason))

        let writeStart = DispatchTime.now()
        let url = dir.appendingPathComponent(filename)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw CaptureWriterError.writeFailed(error.localizedDescription)
        }
        let writeMillis = Int(DispatchTime.now().uptimeNanoseconds - writeStart.uptimeNanoseconds) / 1_000_000

        let sha = SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
        let latency = Int((decisionTimestamp - frameTimestamp) * 1000)
        let relative = "SmartShot/"
            + (organizeByDate ? Self.dayString(now) + "/" : "")
            + filename

        let meta = ShotMetadata(
            filename: filename, relativePath: relative,
            captureFrameTimestamp: frameTimestamp, decisionTimestamp: decisionTimestamp,
            latencyMillis: latency, width: width, height: height,
            reason: reason, reasonDetail: reasonDetail,
            sha256: sha, byteCount: data.count,
            encodeMillis: encodeMillis, writeMillis: writeMillis,
            target: target, parameters: parameters, appVersion: appVersion)
        return WriteOutcome(metadata: meta, skipped: false)
    }

    // MARK: - 命名与编码

    public static func dayString(_ date: Date, tz: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = tz
        return f.string(from: date)
    }

    public static func filenameBase(now: Date, reason: TriggerReason, tz: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.dateFormat = "HHmmss_SSS"
        f.timeZone = tz
        return "\(f.string(from: now))_\(reason.rawValue)"
    }

    private func uniqueFilename(in dir: URL, base: String) -> String {
        let ext = format.pathExtension
        var name = "\(base).\(ext)"
        var idx = 2
        while FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path) {
            name = "\(base)_\(idx).\(ext)"
            idx += 1
        }
        return name
    }

    public static func makeCGImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        let ci = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext(options: [.useSoftwareRenderer: false])
        return context.createCGImage(ci, from: CGRect(x: 0, y: 0,
                                                      width: CVPixelBufferGetWidth(pixelBuffer),
                                                      height: CVPixelBufferGetHeight(pixelBuffer)))
    }

    public static func encode(cgImage: CGImage, format: ImageFormat, quality: Double) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, format.cgIdentifier, 1, nil) else {
            throw CaptureWriterError.encodeFailed
        }
        var props: [CFString: Any] = [:]
        if format == .jpeg {
            props[kCGImageDestinationLossyCompressionQuality] = quality
        }
        CGImageDestinationAddImage(dest, cgImage, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CaptureWriterError.encodeFailed }
        return data as Data
    }
}
