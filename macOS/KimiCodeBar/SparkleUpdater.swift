import Foundation
import AppKit
import Sparkle

final class SparkleUpdater: ObservableObject {
    static let shared = SparkleUpdater()

    private let updaterController: SPUStandardUpdaterController
    private let delegate: UpdaterDelegate

    @Published var isUpdateAvailable = false
    @Published var didDownloadFail = false

    private init() {
        let delegate = UpdaterDelegate()
        self.delegate = delegate
        self.updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: delegate,
            userDriverDelegate: nil
        )
        delegate.owner = self
    }

    /// 后台静默检查是否有新版本（不弹窗、不自动下载）
    func checkForUpdatesInBackground() {
        updaterController.updater.checkForUpdatesInBackground()
    }

    /// 弹出 Sparkle 标准更新窗口（含更新日志、进度条、立即更新/稍后/跳过）
    func showStandardUpdateUI() {
        // 先把本 App 提到最前，避免菜单栏面板关闭后 Sparkle 弹窗落到 Safari 等其它窗口底下
        NSApplication.shared.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            self.updaterController.checkForUpdates(nil)
        }
    }

    /// 打开 GitHub Releases 页面让用户手动下载
    func openGitHubReleases() {
        if let url = URL(string: "https://github.com/xifandev/KimiCodeBar/releases/") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Inner Delegate

    private final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
        weak var owner: SparkleUpdater?

        func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
            DispatchQueue.main.async {
                self.owner?.isUpdateAvailable = true
                self.owner?.didDownloadFail = false
            }
        }

        func updater(_ updater: SPUUpdater, didNotFindUpdate error: Error) {
            DispatchQueue.main.async {
                self.owner?.isUpdateAvailable = false
            }
        }

        func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: Error) {
            DispatchQueue.main.async {
                self.owner?.didDownloadFail = true
            }
        }
    }
}
