import SmartShotCore
import SwiftUI
import AppKit

@main
struct SmartShotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()
    @ObservedObject private var settings = AppSettings.shared

    var body: some Scene {
        // id="main"：菜单栏「打开主窗口」通过 openWindow(id:) 定位此场景。
        WindowGroup("Smart Shot", id: "main") {
            MainWindowView()
                .environmentObject(appState)
                .background(WindowAccessor { window in
                    window.isReleasedWhenClosed = false
                })
        }
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
        }

        // 注意：SceneBuilder 不支持运行时条件场景（仅 #available），菜单栏图标常驻；
        // Settings 里的「显示菜单栏图标」开关为预留项，见 GeneralSettingsTab 说明。
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appState)
        } label: {
            Image(systemName: appState.isRunning ? "camera.fill" : "camera")
        }
        .menuBarExtraStyle(.menu)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !AppSettings.shared.keepRunningOnClose
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    /// 主窗口被关闭后点程序坞图标：重新显示主窗口（关闭不销毁，见 WindowAccessor）。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        guard !hasVisibleWindows else { return true }
        if let main = sender.windows.first(where: { $0.title == "Smart Shot" }) {
            main.makeKeyAndOrderFront(nil)
            return false
        }
        return true
    }
}

/// 在 SwiftUI 层拿到 NSWindow 做少量 AppKit 配置。
struct WindowAccessor: NSViewRepresentable {
    var onWindow: (NSWindow) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { [weak v] in
            if let window = v?.window { onWindow(window) }
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
