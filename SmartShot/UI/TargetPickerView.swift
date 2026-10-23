import SmartShotCore
import SwiftUI
import ScreenCaptureKit

/// 目标选择器：显示器 / 窗口列表。
struct TargetPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var settings = AppSettings.shared
    @State private var targets: AvailableTargets?
    @State private var loadError: String?
    @State private var needsPermission = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if needsPermission {
                permissionBanner
            }
            if let error = loadError {
                Text(error).foregroundStyle(.red).padding()
            }
            if let targets {
                List {
                    Section("显示器") {
                        ForEach(targets.displays) { d in
                            targetRow(kind: .display, id: d.id, title: d.name,
                                      subtitle: "\(d.width)×\(d.height)",
                                      app: nil, appName: nil, window: nil,
                                      w: d.width, h: d.height)
                        }
                    }
                    Section("应用窗口") {
                        if targets.windows.isEmpty {
                            Text("没有可见的应用窗口").foregroundStyle(.secondary)
                        }
                        ForEach(targets.windows) { w in
                            targetRow(kind: .window, id: w.id,
                                      title: w.windowTitle.isEmpty ? "(无标题)" : w.windowTitle,
                                      subtitle: "\(w.width)×\(w.height)",
                                      app: w.appBundleID, appName: w.appName, window: w,
                                      w: w.width, h: w.height)
                        }
                    }
                }
            } else if loadError == nil && !needsPermission {
                ProgressView("正在扫描屏幕与窗口…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 520, height: 480)
        .navigationTitle("选择监控目标")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("刷新") { load() }
            }
        }
        .onAppear { load() }
    }

    private var permissionBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("需要屏幕录制权限", systemImage: "exclamationmark.shield")
                .font(.headline)
            Text("Smart Shot 需要屏幕录制权限才能读取屏幕内容。授予后请点击“刷新”。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("打开系统设置") {
                    NSWorkspace.shared.open(ScreenPermission.systemSettingsURL)
                }
                Button("请求权限") { ScreenPermission.request() }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.yellow.opacity(0.15))
    }

    private func targetRow(kind: CaptureTargetKind, id: UInt32, title: String, subtitle: String,
                           app: String?, appName: String?, window: AvailableTargets.WindowInfo?,
                           w: Int, h: Int) -> some View {
        let target = CaptureTargetID(kind: kind, id: id, appBundleID: app, appName: appName,
                                     windowTitle: window?.windowTitle, pixelWidth: w, pixelHeight: h)
        let selected = settings.savedTarget?.kind == kind && settings.savedTarget?.id == id
        return Button {
            settings.saveTarget(target)
            dismiss()
        } label: {
            HStack(spacing: 10) {
                if let window {
                    WindowThumbnailView(window: window)
                        .frame(width: 64, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                } else {
                    Image(systemName: "display")
                        .frame(width: 64, height: 40)
                        .background(Color.gray.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(appName ?? title).font(.body)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func load() {
        loadError = nil
        needsPermission = false
        Task {
            do {
                let t = try await AvailableTargets.fetch()
                self.targets = t
            } catch CaptureServiceError.screenRecordingDenied {
                self.needsPermission = true
            } catch {
                self.loadError = error.localizedDescription
            }
        }
    }
}

/// 窗口缩略图（一次性截图，非持续采集）。
struct WindowThumbnailView: View {
    let window: AvailableTargets.WindowInfo
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1, orientation: .up)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(Color.gray.opacity(0.15))
            }
        }
        .task { await capture() }
    }

    private func capture() async {
        guard CGPreflightScreenCaptureAccess() else { return }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let w = content.windows.first(where: { $0.windowID == window.id }) else { return }
        let filter = SCContentFilter(desktopIndependentWindow: w)
        let config = SCStreamConfiguration()
        config.width = 128
        config.height = 80
        config.showsCursor = false
        if let cb = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) {
            self.image = cb
        }
    }
}
