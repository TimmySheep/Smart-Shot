import Foundation

/// 8-bit 灰度分析帧。检测管线的统一输入格式。
///
/// 与研究管线对齐：ffmpeg `scale=320:180,format=gray` 的产物就是这种
/// 逐行紧密排列的 8-bit 灰度字节；Swift 侧从 CVPixelBuffer 转换时必须
/// 使用同样的归一化（BT.601/709 加权由 vImage 统一处理，见 GrayConverter）。
public struct GrayFrame: Sendable {
    public let width: Int
    public let height: Int
    public let bytes: [UInt8]

    public init(width: Int, height: Int, bytes: [UInt8]) {
        precondition(bytes.count == width * height, "GrayFrame 字节数必须等于 width*height")
        self.width = width
        self.height = height
        self.bytes = bytes
    }

    /// 从连续字节流按偏移读取一帧（用于 .gray 文件回放）。
    public init(raw: [UInt8], offset: Int, width: Int, height: Int) {
        let n = width * height
        precondition(offset + n <= raw.count, "raw 流越界")
        self.width = width
        self.height = height
        self.bytes = Array(raw[offset..<(offset + n)])
    }
}

/// 两级局部区域变化检测器。
///
/// 语义与研究 `p4_detector.py` 的 `cheap_bits` + `region_counts` 逐位一致：
///  第一级：整帧 XOR 置位计数（代价极低的预筛）。
///  第二级：排除菜单栏/Dock 行后的 8×4 分区，逐像素 |Δ|>pixelThreshold 计数，
///          取分区峰值与总变化像素。
public struct RegionChangeAnalyzer: Sendable {
    public let params: DetectionParameters

    public init(params: DetectionParameters) {
        self.params = params
    }

    /// 第一级：整帧 XOR 置位数。
    public static func xorBits(_ a: GrayFrame, _ b: GrayFrame) -> Int {
        precondition(a.bytes.count == b.bytes.count)
        var bits = 0
        a.bytes.withUnsafeBufferPointer { ap in
            b.bytes.withUnsafeBufferPointer { bp in
                var i = 0
                let n = a.bytes.count
                while i + 8 <= n {
                    let x = ap[i] ^ bp[i]
                    bits += x.nonzeroBitCount
                    bits += (ap[i+1] ^ bp[i+1]).nonzeroBitCount
                    bits += (ap[i+2] ^ bp[i+2]).nonzeroBitCount
                    bits += (ap[i+3] ^ bp[i+3]).nonzeroBitCount
                    bits += (ap[i+4] ^ bp[i+4]).nonzeroBitCount
                    bits += (ap[i+5] ^ bp[i+5]).nonzeroBitCount
                    bits += (ap[i+6] ^ bp[i+6]).nonzeroBitCount
                    bits += (ap[i+7] ^ bp[i+7]).nonzeroBitCount
                    i += 8
                }
                while i < n {
                    bits += (ap[i] ^ bp[i]).nonzeroBitCount
                    i += 1
                }
            }
        }
        return bits
    }

    public func xorBits(_ a: GrayFrame, _ b: GrayFrame) -> Int {
        Self.xorBits(a, b)
    }

    /// 第二级：分区变化像素统计。
    ///
    /// - Returns: `(grid, total, peak)`：grid 为逐行（row-major）分区计数，
    ///   total 为全图变化像素总数，peak 为最大分区计数。
    /// - 与 Python 版一致的边界细节：分区行高 `(bodyH)/nby` 整除截断，
    ///   底部余数行归入最后一行分区；分区列宽 `W/nbx` 整除截断，
    ///   右侧余数列归入最后一列分区。
    public func regionCounts(cur: GrayFrame, ref: GrayFrame) -> (grid: [Int], total: Int, peak: Int) {
        precondition(cur.width == ref.width && cur.height == ref.height)
        let W = cur.width, H = cur.height
        let nbx = params.gridColumns, nby = params.gridRows
        let pixTh = params.pixelThreshold
        let r0 = params.excludeTopRows
        let r1 = H - params.excludeBottomRows
        precondition(r1 > r0, "排除行配置非法")
        let hh = (r1 - r0) / nby
        let ww = W / nbx
        precondition(hh > 0 && ww > 0)

        var grid = [Int](repeating: 0, count: nbx * nby)
        var total = 0
        let cb = cur.bytes, rb = ref.bytes
        for r in r0..<r1 {
            var by = (r - r0) / hh
            if by >= nby { by = nby - 1 }
            let ro = r * W
            let gridRow = by * nbx
            for c in 0..<W {
                // 与 Python 版一致：带符号差的绝对值（不能用 UInt8 环绕减法）
                let dv = abs(Int(cb[ro + c]) - Int(rb[ro + c]))
                if dv > pixTh {
                    var bx = c / ww
                    if bx >= nbx { bx = nbx - 1 }
                    grid[gridRow + bx] += 1
                    total += 1
                }
            }
        }
        var peak = 0
        for v in grid where v > peak { peak = v }
        return (grid, total, peak)
    }
}
