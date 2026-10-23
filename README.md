# Smart Shot

原生 macOS 智能截图 App（Swift + SwiftUI + ScreenCaptureKit）。

两种工作模式：

- **智能模式**：以 1fps 分析目标画面，只在画面内容真正变化时保存 PNG
  （算法移植自《智能截图视频级研究_20261023》冻结配置，逐帧等价性已验证）。
- **定时模式**：独立可用，按固定间隔保存，不依赖检测算法。

质量与可靠性优先于数量和速度：PNG 无损默认、SHA-256 校验、JSONL 事件日志、
内存帧缓冲回存、心跳保底。

## 环境要求

- macOS 14+（开发机为 macOS 27.0.1 / Xcode 27.1 / Swift 6.4）
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)（工程由 `project.yml` 生成；本机已装 2.46.0）

## 构建

```bash
# 1. 从 project.yml 生成工程
xcodegen generate

# 2. 构建 App（Release，正式签名）
xcodebuild -project SmartShot.xcodeproj -scheme SmartShot \
    -configuration Release build

# 3. 运行测试（含与 Python 参考实现的逐帧等价性验证）
xcodebuild -project SmartShot.xcodeproj -scheme SmartShotCore-Test \
    -configuration Debug test
```

签名：Automatic，Team `JY5U4D6JD3`，证书 `Apple Development: timmysh34@icloud.com`。
（注意：证书 CN 括号内的 `L6544N692J` 不是 Team ID；Team ID 是 OU 字段 `JY5U4D6JD3`。）

构建产物：`build/SmartShot.app`（已签 Apple Development + hardened runtime）。

## 首次运行：屏幕录制权限

1. 打开 `build/SmartShot.app`。
2. App 会提示需要「屏幕录制」权限，点击跳转系统设置。
3. 系统设置 → 隐私与安全性 → 屏幕录制 → 打开 Smart Shot。
4. **完全退出并重新打开 App**（macOS 要求重启 App 才生效）。

未授权时 App 不会保存任何截图，只记录权限异常事件到日志。

## 使用

- 菜单栏图标打开主窗口，选择目标（窗口 / 显示器），点「开始」。
- 截图默认保存在 `~/Pictures/SmartShot/<日期>/`，每张附带同名 `.json` 元数据
  （时间戳、SHA-256、触发原因、延迟等）。
- 事件日志：`~/Library/Application Support/SmartShot/events.jsonl`。

## 回放工具（算法验证）

```bash
smartshot-replay --gray <file.gray> --width 320 --height 180 \
    --params '{"prefilter":8000,"region":20,"page_px":3000,"persist":2,"blip_rescue":true,"heartbeat":60}'
```

输出与 Python `p4_detector.py` 相同格式的 JSON，用于逐帧等价性比对。

## 文档

- `docs/architecture.md` — 模块结构与关键设计
- `docs/testing.md` — 测试与等价性验证结果
- `docs/performance.md` — 性能实测数据
- `docs/smart-vs-timed.md` — 智能模式 vs 定时模式对照方案
- `docs/known-limitations.md` — 已知限制与风险（务必阅读）
- `taskbook/任务书.md` — 需求来源
