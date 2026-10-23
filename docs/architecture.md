# 架构说明

## Target 结构

| Target | 类型 | 说明 |
|---|---|---|
| SmartShotCore | Framework | 全部可测试逻辑：检测、策略、写盘、日志。不依赖 SwiftUI。 |
| SmartShot | App | SwiftUI UI + ScreenCaptureKit 采集，仅薄层。 |
| smartshot-replay | CLI | .gray 流回放工具，输出与 Python 参考同格式 JSON。 |
| SmartShotCoreTests | Unit tests | 合成场景 + 回放等价性 + 组件测试。 |

## SmartShotCore 模块

```
Models.swift               数据模型：CaptureTargetID、ShotMetadata、JournalEvent、TriggerReason
DetectionParameters.swift  参数（默认值 = 研究冻结配置）
GrayFrame.swift            8-bit 灰度帧 + RegionChangeAnalyzer（两级检测）
CapturePolicy.swift        策略状态机（F 缓冲 + 保底 + 冷却 + 动态采样）
FrameBuffer.swift          有界内存环形帧缓冲（容量/字节双预算）
CaptureWriter.swift        PNG/JPEG 编码、SHA-256、原子写盘、元数据 JSON
EventJournal.swift         JSONL 追加日志（绝不重写历史行）
GrayConverter.swift        CVPixelBuffer → 320×180 灰度（vImage，BT.601）
```

## 检测管线（两级，与研究 p4_detector.py 逐位对齐）

```
CVPixelBuffer (BGRA, 全分辨率)
   └─ GrayConverter: vImage 缩放 + BT.601 灰度 → 320×180 GrayFrame (57.6KB)
        └─ 第一级: 整帧 XOR 置位计数 (xorBits)
             └─ 未过 prefilterBits(8000) → 预筛未命中，结束
                  └─ 第二级: 排除菜单栏(0..<4)/Dock(171..<180)行，
                     8×4 分区逐像素 |Δ|>25 计数 → (grid, total, peak)
                      └─ total>pagePixels(3000) 或 peak>regionPeak(20) → 超阈值
```

成立前提：**320×180 灰度输入、1fps 检测帧率**。改分辨率或帧率会使冻结阈值失效。

## 策略状态机（CapturePolicy.step）

```
首帧 → 保存
心跳检查（heartbeatSeconds>0 且距上次保存超时）→ 先解决 pending，再保底保存
两级检测 → over?
  ├─ 动态模式中：按 dynamicSampleSeconds 采样 / 连续安静 N 帧退出并保存
  ├─ 未超阈值：解决 pending（blip rescue 或丢弃）
  ├─ 动态进入判断（App 层新增，研究未覆盖）
  ├─ 冷却检查（App 层新增，研究配置=0 即关闭）
  └─ pending 累计 persistFrames 帧 → 回存待定窗口最早一帧（最小延迟，保留瞬变）
```

因果性：step 只使用当前帧与自身状态，绝不使用未来帧
（`testCausalityPrefixStability` 用截断重放前缀一致性证明）。

### 与 Python 参考的关键语义对应

| Python (p4_detector.py) | Swift (CapturePolicy) |
|---|---|
| `heartrate=None` 即关闭 | `heartbeatSeconds <= 0` 关闭 |
| `persist=1` 立即保存 | `persistFrames=1` |
| C_region 无 page_px 逻辑 | C 配置下把 `pagePixels` 设为不触发的极大值 |
| `on_save` 更新 last/last_t | `commitSave` 更新 lastSavedFrame/lastSavedT |

## App 层

```
App/SmartShotApp.swift    入口：主窗口 scene + MenuBarExtra
App/AppState.swift        全局状态：会话启停、设置、历史
Capture/CaptureService.swift  SCShareableContent 获取、窗口/显示器枚举
Capture/CaptureSession.swift  SCStream 采集 → GrayConverter → CapturePolicy → CaptureWriter
Settings/AppSettings.swift    UserDefaults 持久化（模式、间隔、输出目录等）
UI/                        主窗口、目标选择、菜单栏、设置、历史列表
```

## 线程模型

- 采集回调（SCStream 队列）串行驱动 CapturePolicy——状态机非线程安全，单队列独占。
- 写盘（编码 + SHA-256 + 落盘）在独立 utility 队列，不阻塞采集。
- EventJournal 内部串行队列追加，flush 时同步。
