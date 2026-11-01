# 安装 Smart Shot 到 MacBook Pro

- 用户明确要求安装到 MBP；本机 ComputerName 确认为 Tim's MacBook Pro，架构 arm64。
- 安装前确认 `/Applications/SmartShot.app` 与 `/Applications/Smart Shot.app` 均不存在。
- 使用 `ditto build/SmartShot.app /Applications/SmartShot.app` 安装已有交付产物；未安装依赖、未覆盖其他 App，未改动 Auto Shot。
- 安装后 `codesign --verify --deep --strict /Applications/SmartShot.app` 通过。
- 回读 bundle ID：`com.timmysh34.smartshot`，版本 `0.1.0`。
- 未启动采集、未修改屏幕录制权限；真实采集与稳定性仍未验收。
- 本次未创建临时安装包或缓存，没有待清理的安装临时文件。
