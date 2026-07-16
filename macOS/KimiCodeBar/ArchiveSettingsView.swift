import SwiftUI

// MARK: - 列表过滤

private enum SessionFilter: String, CaseIterable, Identifiable {
    case all
    case archived
    case unarchived
    case eligible

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all: return LanguageManager.tr("全部")
        case .archived: return LanguageManager.tr("已归档")
        case .unarchived: return LanguageManager.tr("未归档")
        case .eligible: return LanguageManager.tr("待归档")
        }
    }
}

// MARK: - 按文件夹分组

private struct WorkspaceGroup: Identifiable {
    let id: String
    let name: String
    let sessions: [KimiSession]
}

// MARK: - 自动归档设置页

struct ArchiveSettingsView: View {
    @StateObject private var manager = KimiArchiveManager.shared
    @StateObject private var languageManager = LanguageManager.shared
    @State private var filter: SessionFilter = .all
    @State private var showArchiveResult = false
    @State private var archiveResultCount = 0

    private var now: Date { Date() }

    private var totalCount: Int { manager.sessions.count }
    private var archivedCount: Int { manager.sessions.filter(\.isArchived).count }
    private var unarchivedCount: Int { manager.sessions.filter { !$0.isArchived }.count }
    private var eligibleCount: Int {
        manager.sessions.filter {
            !$0.isArchived && now.timeIntervalSince($0.updatedAt) > manager.autoArchiveThreshold.timeInterval
        }.count
    }

    private var filteredSessions: [KimiSession] {
        switch filter {
        case .all:
            return manager.sessions
        case .archived:
            return manager.sessions.filter(\.isArchived)
        case .unarchived:
            return manager.sessions.filter { !$0.isArchived }
        case .eligible:
            return manager.sessions.filter {
                !$0.isArchived && now.timeIntervalSince($0.updatedAt) > manager.autoArchiveThreshold.timeInterval
            }
        }
    }

    private var groupedSessions: [WorkspaceGroup] {
        let grouped = Dictionary(grouping: filteredSessions) { $0.folderName }
        return grouped
            .map { WorkspaceGroup(id: $0.key, name: $0.key, sessions: $0.value) }
            .sorted { $0.name < $1.name }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                LText("自动归档")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.kimiTextPrimary)

                // 统计
                SettingsCard {
                    HStack(spacing: 10) {
                        StatBadge(count: totalCount, label: languageManager.tr("总对话"), color: .kimiBlue)
                        StatBadge(count: archivedCount, label: languageManager.tr("已归档"), color: .green)
                        StatBadge(count: unarchivedCount, label: languageManager.tr("未归档"), color: .orange)
                        StatBadge(count: eligibleCount, label: languageManager.tr("待归档"), color: .red)
                    }
                    .padding(16)
                }

                // 自动归档设置
                SettingsCard(
                    footerText: languageManager.tr("开启后，KimiCodeBar 会每小时检查一次，将超过保留期限且未归档的会话自动标记为归档。")
                ) {
                    VStack(alignment: .leading, spacing: 0) {
                        SettingsCardRow(
                            title: languageManager.tr("启用自动归档"),
                            subtitle: languageManager.tr("超过保留期限的会话将被自动归档")
                        ) {
                            Toggle("", isOn: $manager.autoArchiveEnabled)
                                .labelsHidden()
                                .toggleStyle(.switch)
                        }

                        SettingsCardDivider()

                        SettingsCardRow(
                            title: languageManager.tr("归档期限"),
                            subtitle: languageManager.tr("超过该时间未更新的会话会被归档")
                        ) {
                            Picker("", selection: $manager.autoArchiveThreshold) {
                                ForEach(ArchiveThreshold.allCases) { threshold in
                                    Text(threshold.displayName).tag(threshold)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(width: 240)
                            .disabled(!manager.autoArchiveEnabled)
                        }
                    }
                }

                // 操作
                SettingsCard {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 12) {
                            ArchiveActionButton(
                                title: languageManager.tr("立即扫描"),
                                icon: "magnifyingglass",
                                disabled: manager.isScanning
                            ) {
                                Task { await manager.scanSessions() }
                            }

                            ArchiveActionButton(
                                title: eligibleCount > 0 ? languageManager.tr("立即归档 %d 个会话", eligibleCount) : languageManager.tr("暂无符合条件的会话"),
                                icon: "archivebox",
                                disabled: eligibleCount == 0 || manager.isScanning
                            ) {
                                Task {
                                    let count = await manager.archiveAllEligible(threshold: manager.autoArchiveThreshold)
                                    archiveResultCount = count
                                    showArchiveResult = true
                                }
                            }
                        }
                        .padding(16)

                        if let error = manager.lastError {
                            SettingsCardDivider()
                            ErrorMessageView(message: error)
                                .padding(16)
                        }

                        if let date = manager.lastAutoArchiveDate {
                            SettingsCardDivider()
                            HStack {
                                LText("上次自动归档：%1$@，共 %2$d 个会话", KimiArchiveManager.relativeTimeString(from: date), manager.lastAutoArchiveCount)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.kimiTextSecondary)

                                Spacer()
                            }
                            .padding(16)
                        }
                    }
                }

                // 会话列表
                SettingsCard(title: languageManager.tr("会话列表")) {
                    VStack(alignment: .leading, spacing: 0) {
                        Picker("", selection: $filter) {
                            ForEach(SessionFilter.allCases) { filter in
                                Text(filter.displayName).tag(filter)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .padding(16)

                        Divider()
                            .background(Color.kimiTextPrimary.opacity(0.08))
                            .padding(.leading, 16)

                        if manager.isScanning {
                            ProgressView()
                                .controlSize(.small)
                                .frame(maxWidth: .infinity, minHeight: 120)
                        } else if groupedSessions.isEmpty {
                            LText("没有符合条件的会话")
                                .font(.system(size: 13))
                                .foregroundStyle(.kimiTextSecondary)
                                .frame(maxWidth: .infinity, minHeight: 120)
                        } else {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(groupedSessions) { group in
                                    WorkspaceHeader(name: group.name, count: group.sessions.count)

                                    ForEach(group.sessions) { session in
                                        SessionRow(
                                            session: session,
                                            threshold: manager.autoArchiveThreshold,
                                            isEligible: !session.isArchived && now.timeIntervalSince(session.updatedAt) > manager.autoArchiveThreshold.timeInterval
                                        ) {
                                            Task { await manager.unarchive(session) }
                                        }

                                        if session.id != group.sessions.last?.id {
                                            Divider()
                                                .background(Color.kimiTextPrimary.opacity(0.06))
                                                .padding(.leading, 16)
                                        }
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 44)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.kimiPanelBackground)
        .onAppear {
            Task { await manager.scanSessions() }
        }
        .onChange(of: manager.autoArchiveEnabled) { _, _ in
            manager.restartTimer()
        }
        .onChange(of: manager.autoArchiveThreshold) { _, _ in
            manager.restartTimer()
        }
        .alert(Text(LanguageManager.tr("归档完成")), isPresented: $showArchiveResult) {
            Button(languageManager.tr("确定"), role: .cancel) {}
        } message: {
            Text(LanguageManager.tr("已成功归档 %d 个会话。", arguments: [archiveResultCount]))
        }
    }
}

// MARK: - 统计徽章

private struct StatBadge: View {
    let count: Int
    let label: String
    let color: Color

    var body: some View {
        VStack(spacing: 6) {
            Text("\(count)")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(color)
                .monospacedDigit()

            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.kimiTextSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(color.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - 操作按钮

private struct ArchiveActionButton: View {
    let title: String
    let icon: String
    var disabled: Bool = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))

                Text(title)
                    .font(.system(size: 13, weight: .medium))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .foregroundStyle(disabled ? .kimiTextTertiary : (isHovered ? .kimiTextPrimary : .kimiTextSecondary))
            .background(disabled ? Color.kimiTextPrimary.opacity(0.04) : (isHovered ? Color.kimiTextPrimary.opacity(0.10) : Color.kimiTextPrimary.opacity(0.06)))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .cursor(disabled ? .arrow : .pointingHand)
        .onHover { isHovered = $0 }
    }
}

// MARK: - 文件夹分组标题

private struct WorkspaceHeader: View {
    let name: String
    let count: Int

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.kimiTextSecondary)

            Text(name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.kimiTextPrimary)

            Text("\(count)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.kimiTextTertiary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.kimiTextPrimary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 4))

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.kimiTextPrimary.opacity(0.04))
    }
}

// MARK: - 取消归档按钮

private struct UnarchiveButton: View {
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            LText("取消归档")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isHovered ? .kimiTextPrimary : .kimiTextSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(isHovered ? Color.kimiTextPrimary.opacity(0.14) : Color.kimiTextPrimary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .cursor(.pointingHand)
        .onHover { isHovered = $0 }
    }
}

// MARK: - 会话行

private struct SessionRow: View {
    let session: KimiSession
    let threshold: ArchiveThreshold
    let isEligible: Bool
    let onUnarchive: () -> Void

    @StateObject private var languageManager = LanguageManager.shared

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(session.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.kimiTextPrimary)
                    .lineLimit(1)

                Text(KimiArchiveManager.archiveTimeDescription(for: session))
                    .font(.system(size: 11))
                    .foregroundStyle(.kimiTextSecondary)
            }

            Spacer()

            if session.isArchived {
                UnarchiveButton(action: onUnarchive)
            } else if isEligible {
                StatusTag(text: languageManager.tr("待归档"), color: .red)
            } else {
                StatusTag(text: languageManager.tr("未归档"), color: .orange)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
