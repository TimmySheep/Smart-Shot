import AppKit
import ImageIO
import SwiftUI

/// 统一视觉令牌与可复用样式（留白、横幅、空状态、缩略图）。
enum Theme {
    /// 分区横向留白。
    static let hPadding: CGFloat = 16
    /// 分区纵向留白。
    static let vPadding: CGFloat = 10
    /// 卡片圆角。
    static let cardRadius: CGFloat = 10
    /// 横幅底色不透明度（各语义色统一）。
    static let bannerOpacity: Double = 0.10
}

extension View {
    /// 分区统一留白。
    func sectionStyle() -> some View {
        padding(.horizontal, Theme.hPadding)
            .padding(.vertical, Theme.vPadding)
    }

    /// 横幅统一底色（图标行 + 内容，语义色淡背景）。
    func bannerStyle(_ tint: Color) -> some View {
        padding(.horizontal, Theme.hPadding)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(Theme.bannerOpacity))
    }
}

/// 版本信息（从主 Bundle 读取，避免散落硬编码）。
enum AppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    /// 形如 `0.1.0 (1)`。
    static var versionLine: String { "\(version) (\(build))" }
}

extension URL {
    /// 展示用路径：家目录缩写为 `~`。
    var tildePath: String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

/// 列表/区域空状态（图标 + 标题 + 可选说明）。
struct EmptyStateView: View {
    let systemImage: String
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title).font(.callout).foregroundStyle(.secondary)
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 24)
    }
}

/// 按需降采样的缩略图缓存（避免为 64×40 预览解码整幅大图）。
enum ThumbnailCache {
    private static let cache = NSCache<NSURL, NSImage>()

    static func image(for url: URL) -> NSImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        guard let image = downsample(url) else { return nil }
        cache.setObject(image, forKey: url as NSURL)
        return image
    }

    private static func downsample(_ url: URL, maxPixel: CGFloat = 200) -> NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

/// 异步缩略图：先占位，后台解码完成后填充（主线程不读盘）。
struct ThumbnailView: View {
    let url: URL
    var size: CGSize
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color.primary.opacity(0.05)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .task(id: url) {
            if let hit = ThumbnailCache.image(for: url) {
                image = hit
                return
            }
            let loaded = await Task.detached(priority: .utility) {
                ThumbnailCache.image(for: url)
            }.value
            image = loaded
        }
    }
}
