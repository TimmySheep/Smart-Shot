import SmartShotCore
import Foundation
import SwiftUI
import AppKit

/// 历史列表条目（从 JSONL 事件解析）。
struct ShotHistoryItem: Identifiable {
    let id = UUID()
    let filename: String
    let relativePath: String
    let date: Date
    let reason: TriggerReason
    let reasonLabel: String
    let width: Int
    let height: Int
    let sha256: String
    let latencyMillis: Int
    let baseURL: URL

    var fileURL: URL { baseURL.appendingPathComponent(relativePath) }

    func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    init?(event: JournalEvent, baseURL: URL) {
        guard let shot = event.shot else { return nil }
        self.filename = shot.filename
        self.relativePath = shot.relativePath
        self.date = Date(timeIntervalSince1970: shot.decisionTimestamp)
        self.reason = shot.reason
        self.reasonLabel = shot.reasonDetail
        self.width = shot.width
        self.height = shot.height
        self.sha256 = shot.sha256
        self.latencyMillis = shot.latencyMillis
        self.baseURL = baseURL
    }
}

/// 全局应用状态：会话管理 + 历史加载。
@MainActor
final class AppState: ObservableObject {
    @Published var session: CaptureSession?
    @Published var recentShots: [ShotHistoryItem] = []
    @Published var isRunning = false

    let settings = AppSettings.shared

    var canStart: Bool {
        settings.savedTarget != nil && ScreenPermission.isGranted
    }

    private var journal: EventJournal?
    private var refreshTask: Task<Void, Never>?

    init() {
        NotificationCenter.default.addObserver(self, selector: #selector(reloadHistory),
                                               name: .smartShotSettingsReset, object: nil)
    }

    func toggleCapture() {
        if isRunning {
            session?.stop()
            isRunning = false
            refreshTask?.cancel()
        } else {
            startCapture()
        }
    }

    private func startCapture() {
        guard let target = settings.savedTarget else { return }
        guard ScreenPermission.isGranted else {
            ScreenPermission.request()
            return
        }
        let params = settings.makeParameters()
        let writer = settings.makeWriter()

        // 事件日志放在 SmartShot 根目录（跨日期追加）
        do {
            let journal = try EventJournal(directory: writer.smartShotRoot)
            self.journal = journal
            let session = CaptureSession(target: target, mode: settings.mode, params: params,
                                         writer: writer, journal: journal)
            session.onFatalWriteError = { [weak self] error in
                DispatchQueue.main.async {
                    self?.recentShots = self?.recentShots ?? []
                    _ = error
                }
            }
            self.session = session
            session.start()
            isRunning = true
            reloadHistory()
            startRefreshLoop()
        } catch {
            // 日志创建失败：会话无法追溯元数据，直接报错
            session = CaptureSession(target: target, mode: settings.mode, params: params,
                                     writer: writer,
                                     journal: try! EventJournal(directory: FileManager.default.temporaryDirectory))
            self.session?.reportError("事件日志创建失败：\(error.localizedDescription)")
        }
    }

    func saveManual() {
        session?.saveManual()
    }

    /// 会话停止后由 UI 调用同步状态。
    func syncStopped() {
        isRunning = session?.status.phase == .running || session?.status.phase == .stopping
    }

    private func startRefreshLoop() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self else { return }
                self.syncStopped()
                self.reloadHistory()
            }
        }
    }

    @objc func reloadHistory() {
        guard let journal else { return }
        let url = journal.fileURL
        let base = settings.outputDirectory
        Task.detached(priority: .utility) {
            let events = EventJournal.readRecent(from: url, limit: 300)
            let items = events.compactMap { ShotHistoryItem(event: $0, baseURL: base) }
            await MainActor.run {
                self.recentShots = Array(items.prefix(100))
            }
        }
    }
}
