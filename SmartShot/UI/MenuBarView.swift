import SmartShotCore
import SwiftUI

/// 菜单栏控制。
struct MenuBarView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var settings = AppSettings.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let status = appState.session?.status
        Button {
            appState.toggleCapture()
        } label: {
            Text(appState.isRunning ? "停止截图" : "开始截图")
        }
        Button("立即保存一张") { appState.saveManual() }
            .disabled(!appState.isRunning)
        Divider()
        if let status {
            Text("已保存 \(status.savedCount) 张")
            if let last = status.lastSaveAt {
                Text("最近：\(MainWindowView.timeFormatter.string(from: last))")
            }
            Text("状态：\(status.detectionState)")
        } else {
            Text("未在运行")
        }
        Divider()
        Picker("模式", selection: $settings.mode) {
            Text("智能").tag(CaptureMode.smart)
            Text("定时").tag(CaptureMode.timed)
        }
        Divider()
        Button("打开主窗口") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "main")
        }
        Button("设置…") {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        Button("退出 Smart Shot") {
            NSApp.terminate(nil)
        }
    }
}
