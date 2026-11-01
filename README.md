# Smart Shot

原生 macOS 智能截图工具。只在画面内容真正发生变化时保存截图，而不是按固定频率堆一堆重复图片。
Native macOS screenshot tool that saves a frame only when the picture actually changes, instead of piling up duplicates on a timer.

[下载 / Download](https://github.com/TimmySheep/Smart-Shot/releases/latest) · [MIT License](#许可--license) · macOS 14+

---

## 它解决什么问题 / What it solves

录课、看直播、跟演示时，画面大部分时间是静止的，只有翻页、写板书、切窗口时才有新信息。
固定间隔截图会产出大量重复图，事后仍要人工挑；Smart Shot 把"变没变"交给检测器判断，只在真正有新内容时落盘。
While recording a lecture or following a demo, the screen is static most of the time — new information appears only on page turns, handwriting, or window switches. Interval-based capture produces mostly duplicates that still need manual sorting. Smart Shot decides "did it change?" in the app and writes a file only when there is new content.

## 两种模式 / Two modes

| 模式 Mode | 行为 Behavior |
|---|---|
| **智能 Smart**（默认 default） | 以 1 fps 分析目标窗口/显示器，画面持续变化才保存；静止期由心跳保底兜底。 Analyzes the target at 1 fps and saves on confirmed change; a heartbeat keeps a floor during static periods. |
| **定时 Timed** | 独立可用，按固定间隔保存，完全不依赖检测算法。 Works standalone: saves at a fixed interval without the detector. |

智能模式的两级检测（整帧 XOR 预筛 → 8×4 分区峰值/总面积）移植自本地研究《智能截图视频级研究_20261023》的冻结参数，
并用 20.mov / 13.mov 的真实课程录像做过**逐帧等价性**回放比对。
The two-stage detector (whole-frame XOR prefilter → 8×4 region peak/area) comes from a local study's frozen parameters and has been verified frame-by-frame against real lecture recordings (20.mov / 13.mov).

## 特点 / Highlights

- **原生像素尺寸**：按实时窗口/显示器几何（`contentRect × pointPixelScale`）采集，Retina 下不丢分辨率。
  **Native resolution**: capture size is derived from live window/display geometry, so Retina detail is preserved.
- **确定性写盘**：PNG 默认无损，附 SHA-256；文件名带毫秒时间戳与触发原因。
  **Deterministic output**: lossless PNG by default with SHA-256; filenames carry a millisecond timestamp and the trigger reason.
- **缓冲回存 / 瞬变抢救**：确认变化后回存**变化发生的那一帧**，而不是延迟后的帧。
  **Buffered re-save / blip rescue**: saves the frame where the change started, not the delayed one.
- **心跳保底**：长时间静止也会按设定间隔留一张，避免检测失效造成盲区。
  **Heartbeat floor**: keeps one frame per interval even when nothing changes, so a detector failure never leaves a blind spot.
- **可观测**：每次运行的触发、抑制、缓冲淘汰、停摆都写入 JSONL 事件日志，事后可追溯。
  **Observable**: triggers, suppressions, buffer evictions and stalls are journaled to JSONL and can be audited afterwards.
- **目标不漂移**：窗口 ID 变化（应用重启）后按「同应用 + 同标题 → 同应用最大窗口」重新解析；过小的工具条/浮层会在选择器里被标注。
  **Stable targeting**: when a window ID changes, the target is re-resolved by "same app + same title → largest window of that app"; suspiciously small helper windows are flagged in the picker.

## 系统要求 / Requirements

- macOS **14.0+**
- 首次运行需授予**屏幕录制**权限 / **Screen Recording** permission on first launch
- 通用二进制，同时含 arm64 与 x86_64 / Universal binary (arm64 + x86_64)

## 安装 / Install

1. 从 [Releases](https://github.com/TimmySheep/Smart-Shot/releases/latest) 下载 `SmartShot-<version>-macOS.zip`，解压后把 `SmartShot.app` 拖入「应用程序」。
   Download the ZIP from Releases, unzip, and drag `SmartShot.app` into Applications.
2. 首次打开：系统设置 → 隐私与安全性 → 屏幕录制 → 允许 Smart Shot，**然后完全退出并重新打开 App**。
   On first launch: System Settings → Privacy & Security → Screen Recording → allow Smart Shot, **then quit and reopen the app**.
3. 未授权时不会保存任何截图，只会记录一条权限异常事件。
   Without permission the app saves nothing and only records a permission event.

> 发布包用 Apple Development 证书签名、**未做公证**。首次打开若被 Gatekeeper 拦下，在 Finder 中右键应用 → 打开。
> Release builds are signed with an Apple Development certificate and are **not notarized**. If Gatekeeper blocks the first launch, right-click the app in Finder → Open.

## 使用 / Usage

- 菜单栏图标打开主窗口 → 「选择…」挑选窗口或显示器 → 「开始截图」。
  Open the main window from the menu bar → pick a window or display → Start.
- 静止期仍会按「保底间隔」出图；嫌多可在设置里把间隔调大（如 30/60 秒）。
  During static periods the heartbeat still produces frames; raise the interval in settings (e.g. 30/60 s) if that is too many.

### 文件位置 / Where files go

| 内容 Content | 位置 Location |
|---|---|
| 截图 Screenshots | `~/Pictures/SmartShot/<YYYY-MM-DD>/` |
| 事件与元数据日志 Event & metadata journal | `~/Pictures/SmartShot/events.jsonl` |

每张图的元数据（SHA-256、触发原因、延迟、采集尺寸、当时生效的检测参数）写在事件日志对应条目里，**不额外生成同名 `.json` 文件**。
Per-shot metadata (SHA-256, trigger reason, latency, capture size, effective parameters) lives in the journal entry — there are **no sidecar `.json` files**.

## 已知限制 / Known limitations

- **细小笔迹可能漏检**：`prefilterBits = 8000`（约 1000 像素差异）是研究选定的折中；合成场景已固化"细笔画漏检"这一行为。需要更灵敏时，在「设置 → 高级」里调低一级预筛阈值（如 8000 → 5000）。
  **Very thin strokes may be missed**: the 8000-bit prefilter (≈1000 changed pixels) is a deliberate trade-off; a synthetic test pins this behavior. For higher sensitivity, lower the prefilter threshold under Settings → Advanced (e.g. 8000 → 5000).
- **分辨率与帧率是阈值前提**：320×180 灰度、1 fps 下标定；改检测帧率会改变行为，UI 中标注为实验性。
  **Resolution and frame rate are part of the calibration**: thresholds assume 320×180 grayscale at 1 fps; higher detection rates are marked experimental.
- 连续动态画面（如视频）走实验性采样路径，研究未覆盖。
  Continuous motion (e.g. video) uses an experimental sampling path that the study did not cover.
- 详见 `docs/known-limitations.md`。 See `docs/known-limitations.md`.

## 从源码构建 / Build from source

```bash
# 1. 生成 Xcode 工程 / generate the project（需要 XcodeGen）
xcodegen generate

# 2. 构建 / build（Release）
xcodebuild -project SmartShot.xcodeproj -scheme SmartShot \
    -configuration Release build

# 3. 测试 / tests（含逐帧等价性回放，约 3 分钟）
xcodebuild -project SmartShot.xcodeproj -scheme SmartShotCore-Test \
    -configuration Debug test
```

- 工程由 `project.yml` 生成；改构建设置请改 `project.yml` 而不是 `.xcodeproj`。
  The Xcode project is generated from `project.yml` — change that file, not the `.xcodeproj`.
- 构建产物在 DerivedData 里；用 `-derivedDataPath build/dd` 可把它固定到仓库内的 `build/`（已被 git 忽略）。
  Products land in DerivedData; pass `-derivedDataPath build/dd` to pin them under the ignored `build/`.
- 签名走 Automatic（Team `JY5U4D6JD3`）。若在**非图形会话**（如 SSH）里构建会报 `errSecInternalComponent`——那是钥匙串私钥需要 GUI 会话，不是代码问题，在图形会话的终端里构建即可。
  Signing uses Automatic signing. Building from a **non-GUI session** (e.g. SSH) fails with `errSecInternalComponent` — that is the keychain requiring a GUI session, not a code issue; build from a terminal inside the logged-in session.

## 测试状态 / Test status

`SmartShotCore-Test`：**32 项通过**（15 项合成场景 + 等价性/组件测试，`0 failures`）。
32 tests pass (15 synthetic scenes plus equivalence and component tests, 0 failures).

这批测试覆盖检测策略、写盘、灰度转换等核心层；采集与 UI 层靠真机实测验证。
They cover the core layer (policy, writer, gray conversion); the capture and UI layers are verified on a real Mac.

## 文档 / Documentation

- `docs/architecture.md` — 模块结构与关键设计 / module layout and key decisions
- `docs/testing.md` — 测试与等价性验证结果 / tests and equivalence results
- `docs/performance.md` — 性能实测数据 / measured performance
- `docs/smart-vs-timed.md` — 智能 vs 定时对照方案 / smart vs timed comparison plan
- `docs/known-limitations.md` — 已知限制与风险 / known limitations and risks
- `taskbook/任务书.md` — 需求来源（中文）/ original requirements (Chinese)
- `logs/` — 开发与验证日志 / development and verification logs

## 许可 / License

[MIT](LICENSE) © 2026 TimmySheep
