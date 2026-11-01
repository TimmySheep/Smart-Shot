import SmartShotCore
import SwiftUI
import ServiceManagement

/// 截图历史窗口。
struct HistoryView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: UUID?
    @State private var filter: TriggerReason?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("截图历史").font(.headline)
                Spacer()
                Picker("", selection: $filter) {
                    Text("全部").tag(TriggerReason?.none)
                    ForEach([TriggerReason.smartChange, .heartbeat, .timed, .blipRescue,
                             .manual, .dynamicSample], id: \.self) { r in
                        Text(label(r)).tag(TriggerReason?.some(r))
                    }
                }
                .frame(width: 160)
                Button("刷新") { appState.reloadHistory() }
            }
            .padding(12)
            Divider()
            if filtered.isEmpty {
                EmptyStateView(
                    systemImage: "camera.on.rectangle",
                    title: filter == nil ? "暂无截图记录" : "没有符合筛选条件的记录",
                    subtitle: filter == nil ? "开始截图后，记录会显示在这里" : "换一个筛选条件试试"
                )
            } else {
                List(filtered, id: \.id, selection: $selectedID) { item in
                    HistoryRow(item: item)
                }
                .listStyle(.inset)
            }
            Divider()
            HStack {
                Text("\(filtered.count) 条").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("在访达中显示") {
                    if let sel = filtered.first(where: { $0.id == selectedID }) { sel.revealInFinder() }
                }.disabled(selectedID == nil)
                Button("打开") {
                    if let sel = filtered.first(where: { $0.id == selectedID }) { NSWorkspace.shared.open(sel.fileURL) }
                }.disabled(selectedID == nil)
            }
            .padding(10)
        }
        .frame(width: 560, height: 480)
        .onAppear { appState.reloadHistory() }
    }

    private var filtered: [ShotHistoryItem] {
        guard let filter else { return appState.recentShots }
        return appState.recentShots.filter { $0.reason == filter }
    }

    private func label(_ r: TriggerReason) -> String {
        switch r {
        case .smartChange: return "画面变化"
        case .heartbeat: return "定时保底"
        case .timed: return "定时"
        case .blipRescue: return "瞬变抢救"
        case .manual: return "手动"
        case .dynamicSample: return "动态采样"
        default: return r.rawValue
        }
    }
}

private struct HistoryRow: View {
    let item: ShotHistoryItem

    var body: some View {
        HStack(spacing: 10) {
            ThumbnailView(url: item.fileURL, size: CGSize(width: 64, height: 40))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.filename).font(.caption).lineLimit(1).truncationMode(.middle)
                Text(item.reasonLabel).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                Text("\(item.width)×\(item.height) · 延迟 \(item.latencyMillis)ms")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(item.date, style: .time).font(.caption2.monospacedDigit())
                Text(item.date, style: .date).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// 设置窗口（任务书 §2.3：通用/截图/保存/高级）。
struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        TabView {
            GeneralSettingsTab().tabItem { Text("通用") }
            CaptureSettingsTab().tabItem { Text("截图") }
            SaveSettingsTab().tabItem { Text("保存") }
            AdvancedSettingsTab().tabItem { Text("高级") }
        }
        .frame(width: 480, height: 420)
    }
}

private struct GeneralSettingsTab: View {
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        Form {
            Toggle("登录时启动", isOn: $settings.launchAtLogin)
            Toggle("关闭窗口时继续后台运行", isOn: $settings.keepRunningOnClose)
            Toggle("显示菜单栏图标", isOn: $settings.showMenuBar)
            Text("当前版本菜单栏图标常驻，此开关为预留项。")
                .font(.caption2).foregroundStyle(.tertiary)
            Spacer()
            Text("Smart Shot 是实验性原型；智能检测不能保证捕获所有短暂内容。")
                .font(.caption).foregroundStyle(.secondary)
            Text("版本 \(AppInfo.versionLine) · © 2026 TimmySheep")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .formStyle(.grouped)
    }
}

private struct CaptureSettingsTab: View {
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        Form {
            Section("模式") {
                Picker("默认模式", selection: $settings.mode) {
                    Text("智能（实验性）").tag(CaptureMode.smart)
                    Text("定时（基准）").tag(CaptureMode.timed)
                }
                Picker("定时截图间隔", selection: $settings.timedIntervalSeconds) {
                    ForEach([10.0, 15.0, 30.0, 60.0], id: \.self) { s in
                        Text("\(Int(s)) 秒").tag(s)
                    }
                }
            }
            Section("智能检测") {
                Picker("保底间隔", selection: $settings.heartbeatSeconds) {
                    ForEach([10.0, 15.0, 30.0, 60.0], id: \.self) { s in
                        Text("\(Int(s)) 秒").tag(s)
                    }
                }
                Picker("灵敏度", selection: $settings.sensitivity) {
                    Text("保守（研究 C15000/60）").tag(0)
                    Text("标准（研究冻结 8000/20）").tag(1)
                    Text("敏感（研究 5000/12）").tag(2)
                }
                Picker("检测帧率", selection: $settings.detectionFPS) {
                    Text("1 帧/秒（研究基准）").tag(1.0)
                    Text("2 帧/秒（实验性）").tag(2.0)
                    Text("5 帧/秒（实验性）").tag(5.0)
                }
                Stepper(value: $settings.cooldownSeconds, in: 0...30, step: 1) {
                    Text("触发冷却：\(Int(settings.cooldownSeconds)) 秒")
                }
                Text("研究结论：2/5 帧率未经重新校准会恶化精度并增加无效截图，更高帧率仅供实验。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Section("连续动态画面（实验性）") {
                Toggle("启用动态采样", isOn: $settings.dynamicEnabled)
                Picker("采样间隔", selection: $settings.dynamicSampleSeconds) {
                    ForEach([10.0, 15.0, 30.0], id: \.self) { s in
                        Text("\(Int(s)) 秒").tag(s)
                    }
                }.disabled(!settings.dynamicEnabled)
                Text("持续高频变化（如影片播放）时停止逐帧触发，改为按间隔采样。"
                     + "字幕与场景切换可能被合并，无法保证全部捕获。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Section("输出") {
                Picker("图片格式", selection: $settings.imageFormat) {
                    Text("PNG（无损，默认）").tag(CaptureWriter.ImageFormat.png)
                    Text("JPEG（体积小）").tag(CaptureWriter.ImageFormat.jpeg)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct SaveSettingsTab: View {
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        Form {
            Section("保存位置") {
                HStack {
                    Text(settings.outputDirectory.path)
                        .lineLimit(1).truncationMode(.middle)
                        .help(settings.outputDirectory.path)
                    Spacer()
                    Button("选择…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.canCreateDirectories = true
                        if panel.runModal() == .OK, let url = panel.url {
                            settings.outputDirectory = url
                        }
                    }
                }
                Text("截图保存在 \(settings.outputDirectory.path)/SmartShot/ 下，"
                     + (settings.organizeByDate ? "按日期分文件夹。" : "不按日期分文件夹。")
                     + "不会修改其他软件的文件。")
                    .font(.caption2).foregroundStyle(.secondary)
                Toggle("按日期组织文件夹", isOn: $settings.organizeByDate)
            }
            Section("磁盘空间") {
                Stepper(value: $settings.minimumFreeGB, in: 1...100, step: 1) {
                    Text("最低可用空间：\(Int(settings.minimumFreeGB)) GB")
                }
                Toggle("空间不足时停止截图（否则跳过该张并记录）", isOn: $settings.stopOnLowDisk)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AdvancedSettingsTab: View {
    @ObservedObject var settings = AppSettings.shared
    @State private var showResetConfirm = false

    var body: some View {
        Form {
            Section("本地检测参数（研究冻结值，改动需重新验证）") {
                Stepper(value: $settings.prefilterBits, in: 1000...40000, step: 500) {
                    Text("一级预筛阈值：\(settings.prefilterBits) 位")
                }
                Stepper(value: $settings.regionPeak, in: 5...200, step: 5) {
                    Text("分区峰值阈值：\(settings.regionPeak) 像素")
                }
                Stepper(value: $settings.pagePixels, in: 500...20000, step: 500) {
                    Text("页面级阈值：\(settings.pagePixels) 像素")
                }
                Stepper(value: $settings.persistFrames, in: 1...5) {
                    Text("持续性确认：\(settings.persistFrames) 帧")
                }
                Toggle("瞬变抢救（研究后验探索性逻辑）", isOn: $settings.blipRescue)
            }
            Section("诊断") {
                HStack {
                    Text("事件日志").font(.caption)
                    Spacer()
                    Button("打开日志目录") {
                        let writer = settings.makeWriter()
                        try? FileManager.default.createDirectory(at: writer.smartShotRoot,
                                                                 withIntermediateDirectories: true)
                        NSWorkspace.shared.open(writer.smartShotRoot)
                    }
                }
                Text("events.jsonl 记录每张截图的时间戳、触发原因、检测参数、SHA-256 与被抑制事件。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Section {
                Button("恢复默认设置", role: .destructive) {
                    showResetConfirm = true
                }
                .confirmationDialog("将清除所有设置并恢复默认值？", isPresented: $showResetConfirm) {
                    Button("恢复默认", role: .destructive) { settings.resetToDefaults() }
                    Button("取消", role: .cancel) {}
                }
            }
        }
        .formStyle(.grouped)
    }
}
