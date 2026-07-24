import Foundation
import AppKit
import Sparkle

final class SparkleUpdater: ObservableObject {
    static let shared = SparkleUpdater()

    private let updaterController: SPUStandardUpdaterController
    private let delegate: UpdaterDelegate

    @Published var isUpdateAvailable = false
    @Published var isUpdateReadyToRestart = false
    @Published var didDownloadFail = false

    /// 自动探测的最小间隔，避免用户高频打开面板时反复请求更新源。
    private let minCheckInterval: TimeInterval = 180 // 3 分钟
    private var lastCheckDate: Date?

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

    /// 探测是否有新版本（不弹窗、不自动下载）
    /// 使用 checkForUpdateInformation 而非 checkForUpdatesInBackground，
    /// 避免用户刚打开面板时 Sparkle 自动弹出更新窗口。
    /// 3 分钟内重复打开面板不会再次触发探测。
    func checkForUpdateInformation() {
        if let last = lastCheckDate, Date().timeIntervalSince(last) < minCheckInterval {
            return
        }
        lastCheckDate = Date()
        updaterController.updater.checkForUpdateInformation()
    }

    /// 弹出 Sparkle 标准更新窗口（含更新日志、进度条、立即更新/稍后/跳过）
    func showStandardUpdateUI() {
        // 先把本 App 提到最前，避免菜单栏面板关闭后 Sparkle 弹窗落到 Safari 等其它窗口底下
        NSApplication.shared.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            self.updaterController.checkForUpdates(nil)
        }
    }

    /// 调用 Sparkle 立即安装并重启
    func restartToInstallUpdate() {
        delegate.installUpdateBlock?()
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
        var installUpdateBlock: (() -> Void)?

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

        func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock: @escaping () -> Void) -> Bool {
            DispatchQueue.main.async {
                self.installUpdateBlock = immediateInstallationBlock
                self.owner?.isUpdateReadyToRestart = true
            }
            return true
        }
    }
}
