import SmartShotCore
import SwiftUI

/// 主窗口（任务书 §2.2）。
struct MainWindowView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var settings = AppSettings.shared
    @State private var showPicker = false
    @State private var showHistory = false
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            targetSection
            Divider()
            modeSection
            Divider()
            statusSection
            Divider()
            if !ScreenPermission.isGranted {
                permissionBanner
                Divider()
            }
            if let err = appState.session?.status.lastError {
                errorBanner(err)
                Divider()
            }
            actionsSection
            Divider()
            recentEvents
        }
        .frame(width: 440, height: 640)
        .sheet(isPresented: $showPicker) { TargetPickerView() }
        .sheet(isPresented: $showHistory) { HistoryView() }
        .sheet(isPresented: $showSettings) { SettingsView() }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
                .resizable().frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text("Smart Shot").font(.headline)
                Text("实验性智能截图").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button { showHistory = true } label: { Image(systemName: "clock") }
                .buttonStyle(.borderless).help("截图历史")
            Button { showSettings = true } label: { Image(systemName: "gearshape") }
                .buttonStyle(.borderless).help("设置")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    // MARK: - 目标

    private var targetSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("监控目标").font(.caption).foregroundStyle(.secondary)
            HStack {
                Image(systemName: targetIcon)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(settings.savedTarget?.displayName ?? "未选择")
                        .font(.callout)
                        .lineLimit(1).truncationMode(.middle)
                    if let t = settings.savedTarget {
                        Text("\(t.pixelWidth)×\(t.pixelHeight) · \(t.kind == .display ? "显示器" : "窗口")")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("选择…") { showPicker = true }
                    .disabled(appState.isRunning)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var targetIcon: String {
        settings.savedTarget?.kind == .display ? "display" : "macwindow"
    }

    // MARK: - 模式

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("模式", selection: $settings.mode) {
                Text("智能").tag(CaptureMode.smart)
                Text("定时").tag(CaptureMode.timed)
            }
            .pickerStyle(.segmented)
            .disabled(appState.isRunning)

            if settings.mode == .smart {
                Picker("保底间隔", selection: $settings.heartbeatSeconds) {
                    ForEach([10.0, 15.0, 30.0, 60.0], id: \.self) { s in
                        Text("\(Int(s)) 秒").tag(s)
                    }
                }
                .disabled(appState.isRunning)
                Text("检测器长时间未触发时的兜底保存间隔。智能检测为实验性功能，短间隔更稳妥。")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Picker("截图间隔", selection: $settings.timedIntervalSeconds) {
                    ForEach([10.0, 15.0, 30.0, 60.0], id: \.self) { s in
                        Text("\(Int(s)) 秒").tag(s)
                    }
                }
                .disabled(appState.isRunning)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    // MARK: - 状态

    private var statusSection: some View {
        let status = appState.session?.status
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("状态").font(.caption).foregroundStyle(.secondary)
                Spacer()
                statusDot
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow {
                    Text("已运行").font(.caption).foregroundStyle(.secondary)
                    Text(formatUptime(status?.uptime ?? 0)).font(.caption.monospacedDigit())
                }
                GridRow {
                    Text("已保存").font(.caption).foregroundStyle(.secondary)
                    Text("\(status?.savedCount ?? 0) 张").font(.caption.monospacedDigit())
                }
                GridRow {
                    Text("最近截图").font(.caption).foregroundStyle(.secondary)
                    Text(status?.lastSaveAt.map(Self.timeFormatter.string(from:)) ?? "—")
                        .font(.caption.monospacedDigit())
                }
                GridRow {
                    Text("触发原因").font(.caption).foregroundStyle(.secondary)
                    Text(reasonText(status?.lastSaveReason, detail: status?.lastSaveDetail))
                        .font(.caption).lineLimit(1)
                }
                GridRow {
                    Text("检测").font(.caption).foregroundStyle(.secondary)
                    Text(detectionText(status)).font(.caption)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var statusDot: some View {
        let phase = appState.session?.status.phase ?? .idle
        let color: Color = phase == .running ? .green : (phase == .error ? .red : .gray)
        return HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(phaseLabel(phase)).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func phaseLabel(_ phase: SessionStatus.Phase) -> String {
        switch phase {
        case .idle: return "空闲"
        case .running: return "运行中"
        case .stopping: return "停止中"
        case .error: return "异常"
        }
    }

    private func reasonText(_ reason: TriggerReason?, detail: String?) -> String {
        guard let reason else { return "—" }
        let name: String
        switch reason {
        case .firstFrame: name = "首帧"
        case .smartChange: name = "画面变化"
        case .blipRescue: name = "瞬变抢救"
        case .heartbeat: name = "定时保底"
        case .timed: name = "定时"
        case .manual: name = "手动"
        case .dynamicStart: name = "动态开始"
        case .dynamicSample: name = "动态采样"
        case .dynamicEnd: name = "动态结束"
        case .fallbackResave: name = "兜底回退"
        }
        return name
    }

    private func detectionText(_ status: SessionStatus?) -> String {
        guard let status, status.phase == .running else { return "—" }
        var s = status.detectionState
        if status.framesProcessed > 0 {
            s += String(format: " · %.1fms/帧", status.analyzerMillisAvg)
        }
        if status.bufferEntries > 0 {
            s += String(format: " · 缓冲 %d 帧/%.0fMB",
                        status.bufferEntries, Double(status.bufferUsedBytes) / 1048576)
        }
        return s
    }

    // MARK: - 权限/错误横幅

    private var permissionBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("需要屏幕录制权限才能开始截图", systemImage: "exclamationmark.shield.fill")
                .font(.callout).foregroundStyle(.orange)
            HStack {
                Button("打开系统设置") { NSWorkspace.shared.open(ScreenPermission.systemSettingsURL) }
                Button("请求权限") { ScreenPermission.request() }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08))
    }

    private func errorBanner(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("运行异常", systemImage: "exclamationmark.triangle.fill")
                .font(.callout).foregroundStyle(.red)
            Text(message).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.08))
    }

    // MARK: - 操作

    private var actionsSection: some View {
        HStack(spacing: 12) {
            Button {
                appState.toggleCapture()
            } label: {
                Text(appState.isRunning ? "停止截图" : "开始截图")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .disabled(!appState.canStart && !appState.isRunning)

            Button {
                appState.saveManual()
            } label: {
                Image(systemName: "camera.viewfinder")
            }
            .controlSize(.large)
            .disabled(!appState.isRunning)
            .help("立即保存一张")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    // MARK: - 最近事件

    private var recentEvents: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("最近截图").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("全部历史…") { showHistory = true }
                    .buttonStyle(.borderless).font(.caption)
            }
            .padding(.horizontal, 16).padding(.vertical, 6)
            Divider()
            if appState.recentShots.isEmpty {
                Text("暂无截图")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(appState.recentShots.prefix(8)) { row in
                            ShotRowView(item: row)
                            Divider()
                        }
                    }
                }
            }
        }
    }

    // MARK: - 工具

    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private func formatUptime(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}

/// 历史列表的一行。
struct ShotRowView: View {
    let item: ShotHistoryItem

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .foregroundStyle(.secondary).frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.filename).font(.caption).lineLimit(1).truncationMode(.middle)
                Text(item.reasonLabel).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(MainWindowView.timeFormatter.string(from: item.date))
                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { item.revealInFinder() }
        .help("点击在访达中显示")
    }

    private var iconName: String {
        switch item.reason {
        case .heartbeat: return "timer"
        case .timed: return "clock"
        case .smartChange: return "sparkles"
        case .blipRescue: return "bolt"
        case .manual: return "hand.tap"
        default: return "camera"
        }
    }
}
