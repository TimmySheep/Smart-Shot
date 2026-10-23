import SmartShotCore
import SwiftUI
import AppKit

@main
struct SmartShotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()
    @ObservedObject private var settings = AppSettings.shared

    var body: some Scene {
        WindowGroup("Smart Shot") {
            MainWindowView()
                .environmentObject(appState)
                .background(WindowAccessor { window in
                    window.isReleasedWhenClosed = false
                })
        }
        .windowResizability(.contentSize)
        .onChange(of: false) { _ in }

        Settings {
            SettingsView()
        }

        MenuBarExtra {
            MenuBarView()
                .environmentObject(appState)
        } label: {
            Image(systemName: appState.isRunning ? "camera.fill" : "camera")
        }
        .menuBarExtraStyle(.menu)
        .onChange(of: settings.showMenuBar) { show in
            // 菜单栏显隐由 MenuBarExtra 场景自身控制；隐藏时退出 app 不适用，
            // 此处仅记录设置（v1 保持菜单栏常驻可见性与设置一致）。
            _ = show
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !AppSettings.shared.keepRunningOnClose
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
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
