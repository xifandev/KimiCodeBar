import Foundation
import SwiftUI

// MARK: - 归档期限

enum ArchiveThreshold: String, CaseIterable, Identifiable {
    case oneDay = "oneDay"
    case oneWeek = "oneWeek"
    case oneMonth = "oneMonth"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .oneDay: return LanguageManager.tr("一天以后")
        case .oneWeek: return LanguageManager.tr("一周以后")
        case .oneMonth: return LanguageManager.tr("一个月以后")
        }
    }

    var timeInterval: TimeInterval {
        switch self {
        case .oneDay: return 24 * 60 * 60
        case .oneWeek: return 7 * 24 * 60 * 60
        case .oneMonth: return 30 * 24 * 60 * 60
        }
    }
}

// MARK: - 会话模型

struct KimiSession: Identifiable, Sendable {
    let id: String
    let workspaceHash: String
    let folderName: String
    let path: URL
    let title: String
    let updatedAt: Date
    let isArchived: Bool

    var relativeTimeText: String {
        KimiArchiveManager.relativeTimeString(from: updatedAt)
    }
}

// MARK: - 归档管理器

@MainActor
final class KimiArchiveManager: ObservableObject {
    static let shared = KimiArchiveManager()

    @Published var autoArchiveEnabled: Bool {
        didSet {
            UserDefaults.standard.set(autoArchiveEnabled, forKey: "autoArchiveEnabled")
            restartTimer()
        }
    }

    @Published var autoArchiveThreshold: ArchiveThreshold {
        didSet {
            UserDefaults.standard.set(autoArchiveThreshold.rawValue, forKey: "autoArchiveThreshold")
            restartTimer()
        }
    }

    @Published var sessions: [KimiSession] = []
    @Published var isScanning = false
    @Published var lastError: String?
    @Published var lastAutoArchiveDate: Date?
    @Published var lastAutoArchiveCount: Int = 0

    private var timer: Timer?
    private let scanInterval: TimeInterval = 60 * 60

    private init() {
        autoArchiveEnabled = UserDefaults.standard.object(forKey: "autoArchiveEnabled") as? Bool ?? false
        if let raw = UserDefaults.standard.string(forKey: "autoArchiveThreshold"),
           let threshold = ArchiveThreshold(rawValue: raw) {
            autoArchiveThreshold = threshold
        } else {
            autoArchiveThreshold = .oneWeek
        }
        restartTimer()
    }

    func restartTimer() {
        timer?.invalidate()
        timer = nil

        guard autoArchiveEnabled else { return }

        performAutoArchiveIfNeeded()

        timer = Timer.scheduledTimer(withTimeInterval: scanInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.performAutoArchiveIfNeeded()
            }
        }
    }

    func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    func performAutoArchiveIfNeeded() {
        guard autoArchiveEnabled else { return }
        Task {
            let count = Self.archiveSessionsOlderThan(threshold: autoArchiveThreshold)
            await MainActor.run {
                self.lastAutoArchiveDate = Date()
                self.lastAutoArchiveCount = count
            }
            await scanSessions()
        }
    }

    func scanSessions() async {
        await MainActor.run {
            isScanning = true
            lastError = nil
        }

        let result = Self.scanSessionsInBackground()

        await MainActor.run {
            self.sessions = result.sessions
            self.lastError = result.error
            self.isScanning = false
        }
    }

    func archiveAllEligible(threshold: ArchiveThreshold) async -> Int {
        await MainActor.run {
            isScanning = true
            lastError = nil
        }

        let count = Self.archiveSessionsOlderThan(threshold: threshold)
        await scanSessions()

        await MainActor.run {
            self.isScanning = false
        }

        return count
    }

    func unarchive(_ session: KimiSession) async {
        await MainActor.run {
            isScanning = true
            lastError = nil
        }

        _ = Self.unarchiveSession(at: session.path)
        await scanSessions()

        await MainActor.run {
            self.isScanning = false
        }
    }

    // MARK: - 后台文件操作

    nonisolated private static func sessionsDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kimi-code/sessions", isDirectory: true)
    }

    nonisolated private static func scanSessionsInBackground() -> (sessions: [KimiSession], error: String?) {
        let directory = sessionsDirectory()
        let fileManager = FileManager.default

        var sessions: [KimiSession] = []
        var errorMessage: String?

        do {
            let workspaceURLs = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: .skipsHiddenFiles
            )

            for workspaceURL in workspaceURLs {
                guard workspaceURL.isDirectory else { continue }

                let sessionURLs = (try? fileManager.contentsOfDirectory(
                    at: workspaceURL,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: .skipsHiddenFiles
                )) ?? []

                for sessionURL in sessionURLs {
                    guard sessionURL.isDirectory else { continue }

                    let stateURL = sessionURL.appendingPathComponent("state.json")
                    guard fileManager.fileExists(atPath: stateURL.path) else { continue }

                    if let session = parseSession(
                        stateURL: stateURL,
                        sessionURL: sessionURL,
                        workspaceURL: workspaceURL
                    ) {
                        sessions.append(session)
                    }
                }
            }
        } catch {
            errorMessage = LanguageManager.tr("无法读取会话目录：%@", arguments: [error.localizedDescription])
        }

        sessions.sort { $0.updatedAt > $1.updatedAt }
        return (sessions, errorMessage)
    }

    nonisolated private static func parseSession(
        stateURL: URL,
        sessionURL: URL,
        workspaceURL: URL
    ) -> KimiSession? {
        guard let data = try? Data(contentsOf: stateURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        guard let updatedAt = parseISODate(json["updatedAt"]) else { return nil }

        let isArchived = (json["archived"] as? Bool) ?? false
        let title = (json["title"] as? String) ?? sessionURL.lastPathComponent
        let folderName = resolveFolderName(from: json) ?? workspaceURL.lastPathComponent

        return KimiSession(
            id: sessionURL.lastPathComponent,
            workspaceHash: workspaceURL.lastPathComponent,
            folderName: folderName,
            path: sessionURL,
            title: title,
            updatedAt: updatedAt,
            isArchived: isArchived
        )
    }

    nonisolated private static func resolveFolderName(from json: [String: Any]) -> String? {
        let startupPath: String?
        if let workDir = json["workDir"] as? String, !workDir.isEmpty {
            startupPath = workDir
        } else if let custom = json["custom"] as? [String: Any],
                  let cwd = custom["cwd"] as? String, !cwd.isEmpty {
            startupPath = cwd
        } else {
            startupPath = nil
        }

        guard let path = startupPath else { return nil }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    nonisolated private static func archiveSessionsOlderThan(threshold: ArchiveThreshold) -> Int {
        let (sessions, _) = scanSessionsInBackground()
        let now = Date()
        var count = 0

        for session in sessions {
            guard !session.isArchived else { continue }
            guard now.timeIntervalSince(session.updatedAt) > threshold.timeInterval else { continue }

            if archiveSession(at: session.path) {
                count += 1
            }
        }

        return count
    }

    nonisolated private static func archiveSession(at sessionURL: URL) -> Bool {
        setArchiveState(at: sessionURL, archived: true)
    }

    nonisolated private static func unarchiveSession(at sessionURL: URL) -> Bool {
        setArchiveState(at: sessionURL, archived: false)
    }

    nonisolated private static func setArchiveState(at sessionURL: URL, archived: Bool) -> Bool {
        let stateURL = sessionURL.appendingPathComponent("state.json")

        guard let data = try? Data(contentsOf: stateURL),
              var json = try? JSONSerialization.jsonObject(
                with: data,
                options: .mutableContainers
              ) as? [String: Any]
        else {
            return false
        }

        let originalUpdatedAt = json["updatedAt"]

        json["archived"] = archived

        var custom = (json["custom"] as? [String: Any]) ?? [:]
        custom["archived"] = archived
        json["custom"] = custom

        // 保持与原文件相同的时间戳格式，避免破坏 Kimi Code 的读取
        if originalUpdatedAt is String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            json["updatedAt"] = formatter.string(from: Date())
        } else if originalUpdatedAt is NSNumber {
            json["updatedAt"] = Int(Date().timeIntervalSince1970 * 1000)
        }

        guard let newData = try? JSONSerialization.data(
            withJSONObject: json,
            options: [.sortedKeys]
        ) else {
            return false
        }

        do {
            try newData.write(to: stateURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    // MARK: - 时间格式化

    nonisolated static func relativeTimeString(from date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.locale = Locale(identifier: LanguageManager.resolvedLanguage == .zhHans ? "zh_CN" : "en_US")
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    nonisolated static func archiveTimeDescription(for session: KimiSession) -> String {
        let relative = relativeTimeString(from: session.updatedAt)
        return session.isArchived
            ? LanguageManager.tr("归档于 %@", arguments: [relative])
            : LanguageManager.tr("更新于 %@", arguments: [relative])
    }

    nonisolated static func parseISODate(_ value: Any?) -> Date? {
        if let string = value as? String {
            let fractionalFormatter = ISO8601DateFormatter()
            fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractionalFormatter.date(from: string) {
                return date
            }

            let plainFormatter = ISO8601DateFormatter()
            plainFormatter.formatOptions = [.withInternetDateTime]
            return plainFormatter.date(from: string)
        }

        if let timestamp = value as? TimeInterval {
            // Kimi Code 新版使用毫秒级 Unix 时间戳
            if timestamp > 1_000_000_000_000 {
                return Date(timeIntervalSince1970: timestamp / 1000)
            }
            return Date(timeIntervalSince1970: timestamp)
        }

        return nil
    }
}

// MARK: - URL 扩展

private extension URL {
    var isDirectory: Bool {
        (try? resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}
