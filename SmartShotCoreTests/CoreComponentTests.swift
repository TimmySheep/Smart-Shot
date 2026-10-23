import XCTest
@testable import SmartShotCore
import CoreVideo
import CryptoKit

/// FrameBuffer：有界内存、淘汰记账、时间戳查找。
final class FrameBufferTests: XCTestCase {

    private func makePixelBuffer(w: Int = 64, h: Int = 64) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA, nil, &pb)
        return pb!
    }

    func testAppendAndLookup() {
        let buf = FrameBuffer(maxEntries: 4, maxBytes: 1 << 30)
        for k in 0..<3 {
            buf.append(makePixelBuffer(), timestamp: TimeInterval(k))
        }
        XCTAssertEqual(buf.count, 3)
        XCTAssertEqual(buf.frame(atOrBefore: 1.5)?.timestamp, 1)
        XCTAssertEqual(buf.nearestFrame(to: 1.5)?.timestamp, 1)
        XCTAssertEqual(buf.latest()?.timestamp, 2)
        XCTAssertNil(buf.frame(atOrBefore: 0.5 - 0.6), "早于所有帧应返回 nil")
    }

    func testEntryCountEviction() {
        let buf = FrameBuffer(maxEntries: 3, maxBytes: 1 << 30)
        var evicted: [String] = []
        buf.onEvict = { _, reason in evicted.append(reason) }
        for k in 0..<6 {
            buf.append(makePixelBuffer(), timestamp: TimeInterval(k))
        }
        XCTAssertEqual(buf.count, 3)
        XCTAssertEqual(evicted.count, 3, "每次超限淘汰都必须记账（不得静默丢弃）")
        XCTAssertEqual(buf.frame(atOrBefore: 2)?.timestamp, nil, "t=2 的帧已被淘汰")
        XCTAssertEqual(buf.latest()?.timestamp, 5)
    }

    func testByteBudgetEviction() {
        // 每帧 64×64 BGRA = 16KB；预算 48KB → 最多 3 帧
        let buf = FrameBuffer(maxEntries: 100, maxBytes: 48 * 1024)
        for k in 0..<10 {
            buf.append(makePixelBuffer(), timestamp: TimeInterval(k))
        }
        XCTAssertLessThanOrEqual(buf.count, 3)
        XCTAssertLessThanOrEqual(buf.usedBytes, 48 * 1024)
    }

    func testRemoveAll() {
        let buf = FrameBuffer(maxEntries: 4, maxBytes: 1 << 30)
        buf.append(makePixelBuffer(), timestamp: 1)
        buf.removeAll()
        XCTAssertEqual(buf.count, 0)
        XCTAssertEqual(buf.usedBytes, 0)
    }
}

/// CaptureWriter：唯一文件名、SHA-256、元数据完整性、不覆盖已有文件。
final class CaptureWriterTests: XCTestCase {

    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("smartshot-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tmpDir { try? FileManager.default.removeItem(at: tmpDir) }
    }

    private func makePixelBuffer(w: Int = 32, h: Int = 24) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA, nil, &pb)
        if let p = pb {
            CVPixelBufferLockBaseAddress(p, [])
            let rb = CVPixelBufferGetBytesPerRow(p)
            let base = CVPixelBufferGetBaseAddress(p)!
                .assumingMemoryBound(to: UInt8.self)
            for r in 0..<h { for c in 0..<(w * 4) { base[r * rb + c] = UInt8((r * c) % 251) } }
            CVPixelBufferUnlockBaseAddress(p, [])
        }
        return pb!
    }

    private var target: CaptureTargetID {
        CaptureTargetID(kind: .window, id: 42, appBundleID: "test.app", appName: "TestApp",
                        windowTitle: "W", pixelWidth: 32, pixelHeight: 24)
    }

    func testSaveWritesFileAndMetadata() throws {
        let writer = CaptureWriter(baseDirectory: tmpDir, format: .png)
        let outcome = try writer.save(pixelBuffer: makePixelBuffer(),
                                      frameTimestamp: 123.456, decisionTimestamp: 123.700,
                                      reason: .smartChange, reasonDetail: "测试",
                                      target: target, parameters: .appDefault)
        let meta = try XCTUnwrap(outcome?.metadata)
        XCTAssertTrue(meta.filename.hasSuffix(".png"))
        XCTAssertTrue(meta.filename.contains("smartChange"))
        XCTAssertTrue(meta.relativePath.hasPrefix("SmartShot/"))
        XCTAssertTrue(meta.relativePath.contains(CaptureWriter.dayString(Date())))
        XCTAssertEqual(meta.width, 32)
        XCTAssertEqual(meta.height, 24)
        XCTAssertEqual(meta.sha256.count, 64)
        XCTAssertGreaterThan(meta.byteCount, 0)
        // 延迟依赖真实时钟，只能验证合理区间（决策到落盘 < 1s）
        XCTAssertGreaterThanOrEqual(meta.latencyMillis, 0)
        XCTAssertLessThan(meta.latencyMillis, 1000)
        // 文件真实存在且 SHA 与内容一致
        let fileURL = tmpDir.appendingPathComponent(meta.relativePath)
        let data = try Data(contentsOf: fileURL)
        XCTAssertEqual(data.count, meta.byteCount)
        let actual = SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(actual, meta.sha256)
    }

    func testUniqueFilenamesNoOverwrite() throws {
        let writer = CaptureWriter(baseDirectory: tmpDir, format: .png)
        var names: [String] = []
        // 同一毫秒内连写 3 张（冻结 now 不可行，依赖文件名冲突递增逻辑）
        for _ in 0..<5 {
            let o = try writer.save(pixelBuffer: makePixelBuffer(),
                                    frameTimestamp: 1, decisionTimestamp: 1,
                                    reason: .timed, reasonDetail: "x",
                                    target: target, parameters: .appDefault)
            names.append(o!.metadata.filename)
        }
        XCTAssertEqual(Set(names).count, names.count, "文件名必须唯一")
        for n in names {
            XCTAssertTrue(FileManager.default.fileExists(atPath:
                tmpDir.appendingPathComponent("SmartShot").appendingPathComponent(
                    CaptureWriter.dayString(Date())).appendingPathComponent(n).path))
        }
    }

    func testJPEGFormat() throws {
        let writer = CaptureWriter(baseDirectory: tmpDir, format: .jpeg, jpegQuality: 0.8)
        let o = try writer.save(pixelBuffer: makePixelBuffer(w: 64, h: 64),
                                frameTimestamp: 1, decisionTimestamp: 1,
                                reason: .heartbeat, reasonDetail: "x",
                                target: target, parameters: .appDefault)
        XCTAssertTrue(o!.metadata.filename.hasSuffix(".jpeg"))
    }

    func testDiskLowStopThrows() throws {
        let writer = CaptureWriter(baseDirectory: tmpDir, format: .png,
                                   minimumFreeBytes: Int64.max, stopOnLowDisk: true)
        XCTAssertThrowsError(try writer.save(pixelBuffer: makePixelBuffer(),
                                             frameTimestamp: 1, decisionTimestamp: 1,
                                             reason: .timed, reasonDetail: "x",
                                             target: target, parameters: .appDefault)) { error in
            guard case CaptureWriterError.diskSpaceLow = error else {
                return XCTFail("应抛出磁盘空间错误，实际 \(error)")
            }
        }
    }

    func testDiskLowSkipReturnsNil() throws {
        let writer = CaptureWriter(baseDirectory: tmpDir, format: .png,
                                   minimumFreeBytes: Int64.max, stopOnLowDisk: false)
        let o = try writer.save(pixelBuffer: makePixelBuffer(),
                                frameTimestamp: 1, decisionTimestamp: 1,
                                reason: .timed, reasonDetail: "x",
                                target: target, parameters: .appDefault)
        XCTAssertNil(o, "跳过模式应返回 nil")
    }
}

/// EventJournal：JSONL 追加、读取最近事件。
final class EventJournalTests: XCTestCase {

    func testAppendAndReadRecent() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("smartshot-journal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let journal = try EventJournal(directory: dir)
        let target = CaptureTargetID(kind: .display, id: 1, pixelWidth: 100, pixelHeight: 100)
        for k in 0..<10 {
            journal.append(JournalEvent(kind: .runtime, timestamp: Double(k),
                                        message: "事件 \(k)",
                                        data: ["k": "\(k)"]))
        }
        journal.flush()

        let events = EventJournal.readRecent(from: journal.fileURL, limit: 5)
        XCTAssertEqual(events.count, 5)
        XCTAssertEqual(events.first?.message, "事件 9", "最新在前")
        XCTAssertEqual(events.last?.message, "事件 5")
        _ = target
    }

    func testShotEventRoundtrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("smartshot-journal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let journal = try EventJournal(directory: dir)
        let target = CaptureTargetID(kind: .window, id: 7, appBundleID: "a.b", appName: "A",
                                     windowTitle: "T", pixelWidth: 2560, pixelHeight: 1440)
        let meta = ShotMetadata(filename: "f.png", relativePath: "SmartShot/f.png",
                                captureFrameTimestamp: 10, decisionTimestamp: 10.5,
                                latencyMillis: 500, width: 2560, height: 1440,
                                reason: .smartChange, reasonDetail: "d",
                                sha256: String(repeating: "ab", count: 32),
                                byteCount: 1000, encodeMillis: 5, writeMillis: 3,
                                target: target, parameters: .appDefault, appVersion: "0.1.0")
        journal.append(JournalEvent(kind: .shot, timestamp: 10, message: "shot", shot: meta))
        journal.flush()

        let events = EventJournal.readRecent(from: journal.fileURL, limit: 10)
        let got = try XCTUnwrap(events.first?.shot)
        XCTAssertEqual(got.filename, "f.png")
        XCTAssertEqual(got.reason, .smartChange)
        XCTAssertEqual(got.sha256, meta.sha256)
        XCTAssertEqual(got.target.appBundleID, "a.b")
        XCTAssertEqual(got.parameters.prefilterBits, 8000)
    }
}

/// GrayConverter：归一化正确性（BT.601 灰度、缩放）。
final class GrayConverterTests: XCTestCase {

    func testSolidColorConversion() throws {
        // 纯红 BGRA → 灰度应为 0.299*255 ≈ 76
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA, nil, &pb)
        let p = pb!
        CVPixelBufferLockBaseAddress(p, [])
        let base = CVPixelBufferGetBaseAddress(p)!.assumingMemoryBound(to: UInt8.self)
        let rb = CVPixelBufferGetBytesPerRow(p)
        for r in 0..<16 { for c in 0..<16 {
            let o = r * rb + c * 4
            base[o] = 0; base[o+1] = 0; base[o+2] = 255; base[o+3] = 255   // BGRA 红
        } }
        CVPixelBufferUnlockBaseAddress(p, [])

        let gray = try XCTUnwrap(GrayConverter.convert(p, targetWidth: 8, targetHeight: 8))
        XCTAssertEqual(gray.width, 8)
        XCTAssertEqual(gray.height, 8)
        // 中心像素应接近 76（299*255/1000 = 76.245 → 76）
        let mid = gray.bytes[4 * 8 + 4]
        XCTAssertEqual(Int(mid), 76, accuracy: 2)
    }

    func testBlackWhiteContrast() throws {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 32, 32, kCVPixelFormatType_32BGRA, nil, &pb)
        let p = pb!
        CVPixelBufferLockBaseAddress(p, [])
        let base = CVPixelBufferGetBaseAddress(p)!.assumingMemoryBound(to: UInt8.self)
        let rb = CVPixelBufferGetBytesPerRow(p)
        for r in 0..<32 { for c in 0..<32 {
            let v: UInt8 = c < 16 ? 0 : 255
            let o = r * rb + c * 4
            base[o] = v; base[o+1] = v; base[o+2] = v; base[o+3] = 255
        } }
        CVPixelBufferUnlockBaseAddress(p, [])
        let gray = try XCTUnwrap(GrayConverter.convert(p, targetWidth: 16, targetHeight: 16))
        // 注意：32→16 的双线性缩放在边界像素（索引 7/8）会混合黑白，
        // 只检查完全落在各自区域内的像素。
        XCTAssertLessThan(Int(gray.bytes[4]), 10, "左黑")
        XCTAssertGreaterThan(Int(gray.bytes[12]), 245, "右白")
    }
}
