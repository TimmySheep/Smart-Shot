import Foundation
import CoreVideo
import Accelerate

/// CVPixelBuffer → 320×180 8-bit 灰度帧。
///
/// 归一化与研究管线对齐：研究侧用 ffmpeg `scale=320:180,format=gray`
/// （先缩放、灰度加权为 BT.601：Y = 0.299R + 0.587G + 0.114B）。
/// 本实现：
///  - 双平面 YCbCr（ScreenCaptureKit 常见输出）：Y 平面即灰度，直接高质量缩放；
///  - 单平面 32bpp（BGRA/ARGB/RGBA 按参数指定）：先全分辨率灰度化（BT.601），
///    再高质量缩放。
public enum GrayConverter {

    public enum PixelLayout: Sendable {
        case bgra, argb, rgba
    }

    /// 将 CVPixelBuffer 转为指定尺寸的灰度帧。
    public static func convert(_ pixelBuffer: CVPixelBuffer,
                               targetWidth: Int = 320, targetHeight: Int = 180,
                               layout: PixelLayout = .bgra) -> GrayFrame? {
        guard targetWidth > 0, targetHeight > 0 else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        var scaled = vImage_Buffer()
        guard vImageBuffer_Init(&scaled, vImagePixelCount(targetHeight),
                                vImagePixelCount(targetWidth), 8,
                                vImage_Flags(kvImageNoFlags)) == kvImageNoError else { return nil }
        defer { scaled.data?.deallocate() }

        let planeCount = CVPixelBufferGetPlaneCount(pixelBuffer)
        if planeCount > 0 && CVPixelBufferIsPlanar(pixelBuffer) {
            // 双平面 420YpCbCr：Y 平面即灰度
            guard let yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return nil }
            var src = vImage_Buffer(
                data: yBase,
                height: vImagePixelCount(CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)),
                width: vImagePixelCount(CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)),
                rowBytes: CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0))
            guard vImageScale_Planar8(&src, &scaled, nil,
                                      vImage_Flags(kvImageHighQualityResampling)) == kvImageNoError
            else { return nil }
        } else {
            // 单平面 32bpp：先灰度化到全分辨率，再缩放
            let srcW = CVPixelBufferGetWidth(pixelBuffer)
            let srcH = CVPixelBufferGetHeight(pixelBuffer)
            guard srcW > 0, srcH > 0,
                  let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
            let srcRowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)

            var fullGray = vImage_Buffer()
            guard vImageBuffer_Init(&fullGray, vImagePixelCount(srcH), vImagePixelCount(srcW),
                                    8, vImage_Flags(kvImageNoFlags)) == kvImageNoError else { return nil }
            defer { fullGray.data?.deallocate() }

            let (ri, gi, bi): (Int, Int, Int) = {
                switch layout {
                case .bgra: return (2, 1, 0)
                case .argb: return (1, 2, 3)
                case .rgba: return (0, 1, 2)
                }
            }()

            let gRB = Int(fullGray.rowBytes)
            fullGray.data!.withMemoryRebound(to: UInt8.self, capacity: srcH * gRB) { grayData in
                let srcData = base.assumingMemoryBound(to: UInt8.self)
                for y in 0..<srcH {
                    let sRow = srcData.advanced(by: y * srcRowBytes)
                    let gRow = grayData.advanced(by: y * gRB)
                    var x = 0
                    // BT.601 整数近似（与 ffmpeg format=gray 同系数）
                    while x < srcW {
                        let o = x * 4
                        let r = Int(sRow[o + ri])
                        let g = Int(sRow[o + gi])
                        let b = Int(sRow[o + bi])
                        gRow[x] = UInt8((299 * r + 587 * g + 114 * b + 500) / 1000)
                        x += 1
                    }
                }
            }
            guard vImageScale_Planar8(&fullGray, &scaled, nil,
                                      vImage_Flags(kvImageHighQualityResampling)) == kvImageNoError
            else { return nil }
        }

        var out = [UInt8](repeating: 0, count: targetWidth * targetHeight)
        let oRB = Int(scaled.rowBytes)
        out.withUnsafeMutableBufferPointer { outBuf in
            scaled.data!.withMemoryRebound(to: UInt8.self, capacity: targetHeight * oRB) { oData in
                for y in 0..<targetHeight {
                    memcpy(outBuf.baseAddress!.advanced(by: y * targetWidth),
                           oData.advanced(by: y * oRB), targetWidth)
                }
            }
        }
        return GrayFrame(width: targetWidth, height: targetHeight, bytes: out)
    }

    /// 从 .gray 原始灰度流文件构建帧数组（回放测试用）。
    public static func loadRawGrayFile(url: URL, width: Int, height: Int,
                                       maxFrames: Int? = nil) throws -> [GrayFrame] {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let fs = width * height
        var frames: [GrayFrame] = []
        frames.reserveCapacity(min((data.count / fs), maxFrames ?? Int.max))
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            var offset = 0
            while offset + fs <= raw.count {
                if let m = maxFrames, frames.count >= m { break }
                frames.append(GrayFrame(width: width, height: height,
                                        bytes: Array(UnsafeBufferPointer(start: base.advanced(by: offset),
                                                                         count: fs))))
                offset += fs
            }
        }
        return frames
    }
}
