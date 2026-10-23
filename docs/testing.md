# 测试与等价性验证

运行方式：

```bash
xcodebuild -project SmartShot.xcodeproj -scheme SmartShotCore-Test \
    -configuration Debug test
```

结果（2026-10-23，macOS 27.0.1 / Xcode 27.1）：

```
Executed 32 tests, with 0 failures — TEST SUCCEEDED
```

## 1. 回放等价性（最重要）

把研究的真实课程录像灰度流（`20_1fps_320x180.gray` 5862 帧、
`13_1fps_320x180.gray` 8408 帧）逐帧喂给 Swift CapturePolicy，
与 Python `p4_detector.py` 的输出**逐时间戳比对**：

| 测试 | 参考 | 结果 |
|---|---|---|
| testFBufferVideo20Equivalence | 20.mov + F_buffer（248 张） | saved_times / stage1_hits / frames 全部一致 ✓ |
| testFBufferVideo13Equivalence | 13.mov + F_buffer（414 张） | 全部一致 ✓ |
| testCRegionVideo20Equivalence | 20.mov + C_region（229 张） | 全部一致 ✓ |
| testCausalityPrefixStability | 截断重放前缀一致性 | 因果性成立 ✓ |

独立 CLI（smartshot-replay）交叉验证同样三条流，结果与测试内回放一致。

含义：**Swift 移植与研究参考实现逐帧等价**——同一输入必然产生同一保存序列。
这不等同于「真实采集 + 转换 + 写盘」等同于离线结果，见 known-limitations。

## 2. 合成场景测试（15 个）

程序生成 320×180 灰度帧覆盖任务书 §5.1 场景：

- 完全相同图像 / 仅鼠标移动 / 进度条（Dock 排除区）→ 不触发
- 正文改写 / 公式推导 / 密集批注 / 图表重绘 / 整页切换 / 窗口缩放 → 触发（缓冲回存到变化首帧）
- 1 秒瞬变画面 → blip rescue 回存；关闭 rescue → 漏检（已知风险的显式记录）
- 细笔画批注 → **不触发**（预筛 <8000 位，冻结配置的已知限制，显式记录）
- 心跳保底 / 冷却抑制 / 连续动态画面进入-采样-退出

注意：冻结参数 prefilter=8000 是硬门槛——像素太少/对比太低的变化不会进入区域分析。
合成场景据此选取 realistic 的变化面积与对比度，并有专门测试固化该限制的行为。

## 3. 组件测试（9 个）

- FrameBuffer：追加/查找、条目数淘汰、字节预算淘汰、清空
- CaptureWriter：PNG 写盘 + 元数据 + SHA-256 回验、文件名唯一性、JPEG、磁盘不足（抛错/跳过两模式）
- EventJournal：JSONL 追加/读取（最新在前）、ShotMetadata 往返
- GrayConverter：纯色 BT.601 精度（红→76±2）、黑白对比边界

## 4. 未覆盖（需真实环境）

- ScreenCaptureKit 真实采集路径（需用户授予屏幕录制权限）
- 30 分钟连续运行稳定性 / 内存 / CPU（需真实运行）
- 真实屏幕 → 320×180 转换与 ffmpeg gray 的逐位一致性（vImage 双线性 vs ffmpeg scale 算法不同，
  只保证亮度语义接近，不保证逐位相同）
