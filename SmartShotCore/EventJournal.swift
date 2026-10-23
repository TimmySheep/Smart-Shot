import Foundation

/// 可追加 JSONL 事件日志（任务书 §3.7）。
///
/// 每行一个 JSON 对象，覆盖：检测/保存/保底事件、被抑制或合并的事件、
/// 权限异常、运行异常、性能采样。追加模式，绝不重写历史行。
public final class EventJournal {
    private let url: URL
    private let queue = DispatchQueue(label: "com.smartshot.journal", qos: .utility)
    private let encoder: JSONEncoder
    private var handle: FileHandle?

    public var onEvent: ((JournalEvent) -> Void)?

    public init(directory: URL, filename: String = "events.jsonl") throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.url = directory.appendingPathComponent(filename)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        self.handle = try FileHandle(forWritingTo: url)
        try self.handle?.seekToEnd()
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.encoder = enc
    }

    deinit {
        try? handle?.close()
    }

    public var fileURL: URL { url }

    public func append(_ event: JournalEvent) {
        queue.async { [self] in
            do {
                var obj = try encoder.encode(event)
                obj.append(0x0A)   // \n
                try handle?.write(contentsOf: obj)
            } catch {
                // 日志失败不能中断截图主流程；stderr 记一笔即可
                fputs("SmartShot journal write failed: \(error)\n", stderr)
            }
            onEvent?(event)
        }
    }

    /// 同步刷盘（会话停止时调用）。
    public func flush() {
        queue.sync {
            try? handle?.synchronize()
        }
    }

    /// 读取最近 N 条事件（供 UI 历史列表）。倒序返回（最新在前）。
    public static func readRecent(from url: URL, limit: Int = 200) -> [JournalEvent] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        // 注意：不可用 `map(String.init)`——会被解析成 String(describing:)，产出 "7 bytes" 之类的描述
        var lines: [String] = data.split(separator: 0x0A)
            .map { String(decoding: $0, as: UTF8.self) }
        if lines.count > limit {
            lines = Array(lines.suffix(limit))
        }
        let decoder = JSONDecoder()
        var result: [JournalEvent] = []
        for line in lines.reversed() {
            if let lineData = line.data(using: .utf8),
               let ev = try? decoder.decode(JournalEvent.self, from: lineData) {
                result.append(ev)
            }
        }
        return result
    }
}
