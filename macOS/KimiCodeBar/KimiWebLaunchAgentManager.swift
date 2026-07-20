import Foundation

/// 仅用于清理旧版本残留的 macOS LaunchAgent。
///
/// Kimi Code 0.28 起 `kimi web` 为前台进程，不再通过 LaunchAgent 启动。
/// 保留此类是为了卸载早期版本可能写入的 plist，防止旧 KeepAlive 配置反复拉起进程。
///
/// 注意：历史 plist 使用 `--dangerous-bypass-auth` 关闭 bearer-token 鉴权，
/// 仅适合在本地可信网络环境使用。
final class KimiWebLaunchAgentManager: @unchecked Sendable {
    static let shared = KimiWebLaunchAgentManager()

    private let label = "com.kimicodebar.kimiweb"

    /// launchd 用户域目标，例如 "gui/501"。
    private var domainTarget: String {
        "gui/\(getuid())"
    }

    /// 完整服务目标，例如 "gui/501/com.kimicodebar.kimiweb"。
    private var serviceTarget: String {
        "\(domainTarget)/\(label)"
    }

    private var launchAgentsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    }

    private var plistURL: URL {
        launchAgentsDir.appendingPathComponent("\(label).plist")
    }

    private var logsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/KimiCodeBar", isDirectory: true)
    }

    private var logURL: URL {
        logsDir.appendingPathComponent("kimi-web.log", isDirectory: false)
    }

    private init() {}

    // MARK: - Public

    /// 写入 plist 并加载到 launchd。
    func install() async {
        await Task.detached(priority: .utility) { () -> Void in
            self.ensureDirectories()
            guard let kimiPath = self.findKimiPath() else { return }

            // 若服务已存在，先 bootout，避免 bootstrap 时报 "already bootstrapped"
            self.runLaunchctl(arguments: ["bootout", self.serviceTarget])

            let plist = self.generatePlist(kimiPath: kimiPath)
            try? plist.write(to: self.plistURL, options: .atomic)

            self.runLaunchctl(arguments: ["bootstrap", self.domainTarget, self.plistURL.path])
        }.value
    }

    /// 启动服务。
    func start() async {
        await Task.detached(priority: .utility) { () -> Void in
            self.runLaunchctl(arguments: ["start", self.label])
        }.value
    }

    /// 停止服务。
    func stop() async {
        await Task.detached(priority: .utility) { () -> Void in
            self.runLaunchctl(arguments: ["stop", self.label])
        }.value
    }

    /// 从 launchd 卸载并删除 plist 文件。
    func uninstall() async {
        await Task.detached(priority: .utility) { () -> Void in
            self.runLaunchctl(arguments: ["bootout", self.serviceTarget])
            try? FileManager.default.removeItem(at: self.plistURL)
        }.value
    }

    /// 检查当前是否已加载。
    func isLoaded() async -> Bool {
        await Task.detached(priority: .utility) {
            let result = self.runLaunchctl(arguments: ["print", self.serviceTarget])
            return result.exitCode == 0
        }.value
    }

    // MARK: - Private

    private func ensureDirectories() {
        try? FileManager.default.createDirectory(
            at: launchAgentsDir,
            withIntermediateDirectories: true,
            attributes: nil
        )
        try? FileManager.default.createDirectory(
            at: logsDir,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }

    private func findKimiPath() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.kimi-code/bin/kimi",
            "\(home)/.kimi/bin/kimi",
            "/usr/local/bin/kimi",
            "/opt/homebrew/bin/kimi",
            "/usr/bin/kimi"
        ]

        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        return nil
    }

    private func generatePlist(kimiPath: String) -> Data {
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [
                kimiPath,
                "web",
                "--no-open",
                "--dangerous-bypass-auth"
            ],
            "RunAtLoad": true,
            "KeepAlive": true,
            "StandardOutPath": logURL.path,
            "StandardErrorPath": logURL.path,
            "EnvironmentVariables": [
                "PATH": "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:\(FileManager.default.homeDirectoryForCurrentUser.path)/.kimi-code/bin:\(FileManager.default.homeDirectoryForCurrentUser.path)/.kimi/bin"
            ]
        ]

        return try! PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
    }

    @discardableResult
    private func runLaunchctl(arguments: [String]) -> (output: String, exitCode: Int32) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = arguments

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return (output.trimmingCharacters(in: .whitespacesAndNewlines), task.terminationStatus)
        } catch {
            return ("", -1)
        }
    }
}
