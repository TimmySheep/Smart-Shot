import SmartShotCore
import SwiftUI

/// 主窗口（任务书 §2.2）。
struct MainWindowView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var settings = AppSettings.shared
    @State private var showPicker = false
    @State private var showHistory = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            targetSection
            Divider()
            modeSection
            Divider()
            saveSection
            Divider()
            statusSection
            if !ScreenPermission.isGranted {
                permissionBanner
            }
            if let err = appState.session?.status.lastError {
                errorBanner(err)
            }
            actionsSection
            Divider()
            recentEvents
        }
        .frame(minWidth: 420, idealWidth: 440, minHeight: 640, idealHeight: 680)
        .sheet(isPresented: $showPicker) { TargetPickerView() }
        .sheet(isPresented: $showHistory) { HistoryView() }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
                .resizable().frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text("实验性智能截图").font(.callout.weight(.semibold))
                Text("本地检测 · 不上传屏幕内容")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { showHistory = true } label: { Image(systemName: "clock") }
                .buttonStyle(.borderless).help("截图历史")
                .accessibilityLabel("截图历史")
            Button { openSettings() } label: { Image(systemName: "gearshape") }
                .buttonStyle(.borderless).help("设置")
                .accessibilityLabel("设置")
        }
        .sectionStyle()
    }

    private func openSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        NSApp.activate(ignoringOtherApps: true)
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
                        .foregroundStyle(settings.savedTarget == nil ? .secondary : .primary)
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
        .sectionStyle()
    }

    private var targetIcon: String {
        settings.savedTarget?.kind == .display ? "display" : "macwindow"
    }

    // MARK: - 模式

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("模式").font(.callout)
                    Picker("", selection: $settings.mode) {
                        Text("智能").tag(CaptureMode.smart)
                        Text("定时").tag(CaptureMode.timed)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .disabled(appState.isRunning)
                }
                GridRow {
                    Text(settings.mode == .smart ? "保底间隔" : "截图间隔").font(.callout)
                    Picker("", selection: intervalBinding) {
                        ForEach([10.0, 15.0, 30.0, 60.0], id: \.self) { s in
                            Text("\(Int(s)) 秒").tag(s)
                        }
                    }
                    .labelsHidden()
                    .disabled(appState.isRunning)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if settings.mode == .smart {
                Text("检测器长时间未触发时的兜底保存间隔。智能检测为实验性功能，短间隔更稳妥。")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .sectionStyle()
    }

    private var intervalBinding: Binding<Double> {
        settings.mode == .smart ? $settings.heartbeatSeconds : $settings.timedIntervalSeconds
    }

    // MARK: - 保存位置

    private var saveSection: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("保存位置").font(.caption).foregroundStyle(.secondary)
                Text(saveRoot.tildePath)
                    .font(.callout)
                    .lineLimit(1).truncationMode(.middle)
                    .help(saveRoot.path)
            }
            Spacer()
            Button("在访达中显示") { revealSaveFolder() }
                .font(.caption)
        }
        .sectionStyle()
    }

    private var saveRoot: URL { settings.makeWriter().smartShotRoot }

    private func revealSaveFolder() {
        try? FileManager.default.createDirectory(at: saveRoot, withIntermediateDirectories: true)
        NSWorkspace.shared.open(saveRoot)
    }

    // MARK: - 状态

    private var statusSection: some View {
        let status = appState.session?.status
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                statusDot
                Spacer()
                Text(uptimeText(status))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow {
                    Text("已保存").font(.caption).foregroundStyle(.secondary)
                    Text("\(status?.savedCount ?? 0) 张").font(.callout.monospacedDigit())
                }
                GridRow {
                    Text("最近截图").font(.caption).foregroundStyle(.secondary)
                    Text(status?.lastSaveAt.map(Self.timeFormatter.string(from:)) ?? "—")
                        .font(.callout.monospacedDigit())
                }
                GridRow {
                    Text("触发原因").font(.caption).foregroundStyle(.secondary)
                    Text(reasonText(status?.lastSaveReason, detail: status?.lastSaveDetail))
                        .font(.callout).lineLimit(1)
                }
                GridRow {
                    Text("检测").font(.caption).foregroundStyle(.secondary)
                    Text(detectionText(status)).font(.callout).lineLimit(1)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .fill(Color.primary.opacity(0.045))
        )
        .sectionStyle()
    }

    private func uptimeText(_ status: SessionStatus?) -> String {
        guard let status, status.startedAt != nil else { return "—" }
        return formatUptime(status.uptime)
    }

    private var statusDot: some View {
        let phase = appState.session?.status.phase ?? .idle
        let color: Color = phase == .running ? .green : (phase == .error ? .red : .gray)
        return HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(phaseLabel(phase))
                .font(.callout.weight(.medium))
                .foregroundStyle(phase == .error ? .red : .primary)
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
        .bannerStyle(.orange)
    }

    private func errorBanner(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("运行异常", systemImage: "exclamationmark.triangle.fill")
                .font(.callout).foregroundStyle(.red)
            Text(message).font(.caption).foregroundStyle(.secondary)
        }
        .bannerStyle(.red)
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
            .keyboardShortcut(.defaultAction)
            .disabled(!appState.canStart && !appState.isRunning)

            Button {
                appState.saveManual()
            } label: {
                Image(systemName: "camera.viewfinder")
            }
            .controlSize(.large)
            .disabled(!appState.isRunning)
            .help("立即保存一张")
            .accessibilityLabel("立即保存一张")
        }
        .sectionStyle()
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
            .padding(.horizontal, Theme.hPadding).padding(.vertical, 6)
            Divider()
            if appState.recentShots.isEmpty {
                EmptyStateView(
                    systemImage: "camera.on.rectangle",
                    title: "暂无截图",
                    subtitle: "开始截图后，最近保存的记录会显示在这里"
                )
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

/// 历史列表的一行（缩略图异步加载）。
struct ShotRowView: View {
    let item: ShotHistoryItem

    var body: some View {
        Button {
            item.revealInFinder()
        } label: {
            HStack(spacing: 8) {
                ThumbnailView(url: item.fileURL, size: CGSize(width: 40, height: 26))
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.filename).font(.caption).lineLimit(1).truncationMode(.middle)
                    Text(item.reasonLabel).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Text(MainWindowView.timeFormatter.string(from: item.date))
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Theme.hPadding).padding(.vertical, 5)
        .help("点击在访达中显示")
        .accessibilityLabel("\(item.filename)，\(item.reasonLabel)，\(MainWindowView.timeFormatter.string(from: item.date))")
        .accessibilityHint("在访达中显示此截图")
    }
}
