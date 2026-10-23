import Foundation
import SmartShotCore

/// smartshot-replay：把 .gray 原始灰度流按帧喂给 Swift CapturePolicy，
/// 输出与 Python p4_detector.py 相同格式的 JSON（saved_times 等），
/// 用于逐帧等价性对比。
///
/// 用法：
///   smartshot-replay --gray <path> --width 320 --height 180 \
///       --params '{"prefilterBits":8000,"regionPeak":20,...}' [--start N] [--end N]
///
/// 输出 JSON 字段与 p4_detector.py __main__ 一致：
///   {"detector","params","frames","stage1_hits","saved","elapsed_s","fps","saved_times"}

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write("error: \(msg)\n".data(using: .utf8)!)
    exit(1)
}

func parseInt(_ s: String, _ name: String) -> Int {
    if let v = Int(s) { return v }
    fail("bad \(name): \(s)")   // fail() 为 Never，控制流不会到达函数末尾之后
}

// MARK: - 参数解析

var grayPath = ""
var width = 320, height = 180
var paramsJSON = "{}"
var startFrame = 0
var endFrame: Int?

var args = Array(CommandLine.arguments.dropFirst())
var i = 0
while i < args.count {
    switch args[i] {
    case "--gray": i += 1; grayPath = args[i]
    case "--width": i += 1; width = parseInt(args[i], "width")
    case "--height": i += 1; height = parseInt(args[i], "height")
    case "--params": i += 1; paramsJSON = args[i]
    case "--start": i += 1; startFrame = parseInt(args[i], "start")
    case "--end": i += 1; endFrame = parseInt(args[i], "end")
    default: fail("unknown arg \(args[i])")
    }
    i += 1
}
guard !grayPath.isEmpty else { fail("--gray is required") }

// 解析参数 JSON → DetectionParameters（逐字段映射，保持与 Python 字段名的对应）
var params = DetectionParameters()
params.heartbeatSeconds = 0      // 默认无心跳；p4_detector 参数里给 heartbeat 才启用
params.cooldownSeconds = 0
params.dynamicEnabled = false    // replay 不启用动态采样（App 层新增，研究未覆盖）

if let data = paramsJSON.data(using: .utf8),
   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
    if let v = obj["prefilter"] as? Int { params.prefilterBits = v }
    if let v = obj["region"] as? Int { params.regionPeak = v }
    if let v = obj["page_px"] as? Int { params.pagePixels = v }
    if let v = obj["persist"] as? Int { params.persistFrames = v }
    if let v = obj["heartbeat"] as? Double { params.heartbeatSeconds = v }
    if let v = obj["heartbeat"] as? Int { params.heartbeatSeconds = Double(v) }
    if let v = obj["blip_rescue"] as? Bool { params.blipRescue = v }
    if let v = obj["pix_th"] as? Int { params.pixelThreshold = v }
    if let v = obj["nbx"] as? Int { params.gridColumns = v }
    if let v = obj["nby"] as? Int { params.gridRows = v }
} else {
    fail("bad --params JSON")
}

// MARK: - 加载灰度流

let url = URL(fileURLWithPath: grayPath)
guard FileManager.default.fileExists(atPath: url.path) else { fail("gray file not found: \(grayPath)") }
let frames: [GrayFrame]
do {
    frames = try GrayConverter.loadRawGrayFile(url: url, width: width, height: height)
} catch {
    fail("load gray: \(error)")
}

let end = min(endFrame ?? frames.count, frames.count)
guard startFrame < end else { fail("empty range") }

// MARK: - 顺序回放（因果：t = 帧索引秒，与 p4_detector run() 一致）

let policy = CapturePolicy(params: params)
let t0 = Date()
var savedTimes: [Double] = []
for k in startFrame..<end {
    let actions = policy.step(t: TimeInterval(k), frame: frames[k])
    for action in actions {
        if case .save(let frameT, _, _) = action {
            savedTimes.append(frameT)
        }
    }
}
let elapsed = Date().timeIntervalSince(t0)

// MARK: - 输出（对齐 p4_detector.py 格式）

let out: [String: Any] = [
    "detector": "F_buffer_swift",
    "params": paramsJSON,
    "frames": policy.framesSeen,
    "stage1_hits": policy.stage1Hits,
    "saved": savedTimes.count,
    "elapsed_s": (elapsed * 100).rounded() / 100,
    "fps": elapsed > 0 ? (Double(policy.framesSeen) / elapsed * 10).rounded() / 10 : 0,
    "saved_times": savedTimes,
]
if let outData = try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]),
   let line = String(data: outData, encoding: .utf8) {
    print(line)
} else {
    fail("encode output failed")
}
