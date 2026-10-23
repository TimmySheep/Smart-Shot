# Smart Shot 项目约定

- 项目：原生 macOS 智能截图 App（Swift + SwiftUI + ScreenCaptureKit）。
- 任务书：`taskbook/任务书.md`（用户 2026-10-23 下达，权威需求来源）。
- 开发日志写入本项目 `logs/`（格式见 `logs/README.md`）；任务书/计划写 `taskbook/`。
- 算法依据：`/Users/TimmySheep/AWS/sMDP/work/课程笔记工作流/优化方向/智能截图视频级研究_20261023/`
  （冻结参数在 `core_parameters.json`；检测器参考实现在 `scripts/p4_detector.py`）。
  移植时必须核实输入尺寸与归一化方式（320×180 灰度、像素阈值 25、8×4 分区、排除菜单栏/Dock 行），不得直接照抄数字而不验证。
- 本项目独立于 Auto Shot（/Applications/Auto Shot.app）与 sMDP/V6 生产管线：不修改它们，不接管它们的目录，不接入 V6。
- 删除文件一律 `mv` 到 `~/.Trash/`，禁止 `rm`。
- 构建：Xcode 27.1 + Swift 6.4（语言模式 5），macOS 14+ 目标；工程由 `project.yml`（XcodeGen）生成。
- 签名：Apple Development: timmysh34@icloud.com（L6544N692J），仅本地运行用途。
