import SwiftUI

// MARK: - 本机消耗量数据模型

/// 某一天的本地 Token 消耗（来自 Kimi Code 本地会话记录 wire.jsonl 的 usage.record 事件）
struct LocalUsageDay: Identifiable {
    var id: Date { date }
    let date: Date          // 当天 0 点（本地时区）
    var input: Int = 0      // 输入合计 = 非缓存 + 缓存读 + 缓存写
    var output: Int = 0     // 输出
    var cacheRead: Int = 0  // 缓存读（用于命中率）

    var totalTokens: Int { input + output }
}

/// 用量统计时间范围：累计（默认）/ 今日 / 7天
enum LocalUsageRange: String, CaseIterable, Identifiable {
    case all
    case today
    case week

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all: return LanguageManager.tr("累计")
        case .today: return LanguageManager.tr("今日")
        case .week: return LanguageManager.tr("7天")
        }
    }
}

// MARK: - 增量扫描状态

/// 持久化的扫描状态：每个 wire.jsonl 文件的上次读取字节偏移量 + 累计按天用量。
/// 存储在 ~/Library/Application Support/KimiCodeBar/scan-state.json。
/// 重启 App 后从磁盘恢复，避免全量重扫。
private struct ScanState: Codable {
    /// 相对路径 → 上次读到的字节偏移量
    var offsets: [String: Int] = [:]
    /// 累计按天用量（key = yyyy-MM-dd 日期字符串）
    var daysByKey: [String: LocalUsageDayCodable] = [:]
    /// 按小时用量（key = yyyy-MM-dd-HH），仅保留当天，用于「今日」波浪曲线
    var hoursByKey: [String: Int] = [:]
}

private struct LocalUsageDayCodable: Codable {
    let date: TimeInterval   // 当天 0 点 timeIntervalSince1970
    var input: Int
    var output: Int
    var cacheRead: Int
}

/// 日期 key 格式化器（yyyy-MM-dd），用于状态字典的 key
private let scanDayKeyFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f
}()

// MARK: - 本机消耗量服务

/// 扫描 Kimi Code 本地会话记录（sessions/<工作目录>/<会话>/agents/*/wire.jsonl），
/// 聚合 usage.record 事件得出按天 Token 消耗。
/// 原则：只读，绝不修改官方任何文件；不触碰 credentials；尊重 KIMI_CODE_HOME。
/// 策略：增量扫描 — 记录每个文件的字节偏移量，仅读取新增内容；
/// 状态持久化到 Application Support，重启后从上次位置继续；
/// 结果内存缓存 + 3 分钟节流；扫描在后台线程执行，不阻塞 UI。
@MainActor
final class KimiLocalUsageService: ObservableObject {
    static let shared = KimiLocalUsageService()

    @Published private(set) var days: [LocalUsageDay] = []
    /// 今日按小时用量（24 格，下标为小时），供「今日」波浪曲线使用
    @Published private(set) var todayHours: [Int] = []
    @Published private(set) var isLoading = false
    @Published private(set) var hasScanned = false

    private var lastScanDate: Date?
    private let throttleInterval: TimeInterval = 180

    private init() {}

    /// 面板打开时调用；3 分钟内重复打开不重复扫描
    func refreshIfNeeded() {
        guard !isLoading else { return }
        if let lastScanDate, Date().timeIntervalSince(lastScanDate) < throttleInterval { return }
        isLoading = true
        Task {
            let (scanned, hours, _) = await Task.detached(priority: .utility) {
                Self.scanSessionFiles()
            }.value
            days = scanned
            todayHours = hours
            hasScanned = true
            isLoading = false
            lastScanDate = Date()
        }
    }

    /// 按范围过滤：累计=全部，今日=今天 0 点起，7天=近 7 个自然日（含今天）
    func days(in range: LocalUsageRange) -> [LocalUsageDay] {
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: Date())
        switch range {
        case .all:
            return days
        case .today:
            return days.filter { $0.date >= todayStart }
        case .week:
            let start = calendar.date(byAdding: .day, value: -6, to: todayStart) ?? todayStart
            return days.filter { $0.date >= start }
        }
    }

    // MARK: 数字格式化（随显示语言：中文 亿/万，英文 B/M/K）

    static func formatTokenCount(_ count: Int) -> (value: String, unit: String) {
        if LanguageManager.resolvedLanguage == .zhHans {
            if count >= 100_000_000 { return (scaled(count, by: 100_000_000), "亿") }
            if count >= 10_000 { return (scaled(count, by: 10_000), "万") }
            return ("\(count)", "")
        }
        if count >= 1_000_000_000 { return (scaled(count, by: 1_000_000_000), "B") }
        if count >= 1_000_000 { return (scaled(count, by: 1_000_000), "M") }
        if count >= 1_000 { return (scaled(count, by: 1_000), "K") }
        return ("\(count)", "")
    }

    /// 缩放并保留精度：≥100 取整，否则保留一位小数
    private static func scaled(_ count: Int, by divisor: Double) -> String {
        let value = Double(count) / divisor
        return value >= 100 ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }

    // MARK: 扫描状态持久化

    /// scan-state.json 存储路径
    nonisolated private static var stateFileURL: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let dir = appSupport.appendingPathComponent("KimiCodeBar", isDirectory: true)
        // 确保目录存在
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("scan-state.json")
    }

    /// 从磁盘加载扫描状态（首次安装返回空状态）
    nonisolated private static func loadScanState() -> ScanState {
        guard let data = try? Data(contentsOf: stateFileURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ScanState()
        }
        // v1 状态没有按小时粒度：整体作废，触发一次全量重扫重建（含小时数据）
        guard (json["version"] as? Int ?? 1) >= 2 else { return ScanState() }
        var state = ScanState()
        if let offsets = json["offsets"] as? [String: Int] {
            state.offsets = offsets
        }
        if let hours = json["hours"] as? [String: Int] {
            state.hoursByKey = hours
        }
        if let days = json["days"] as? [String: [String: Any]] {
            for (key, dict) in days {
                state.daysByKey[key] = LocalUsageDayCodable(
                    date: dict["date"] as? TimeInterval ?? 0,
                    input: dict["input"] as? Int ?? 0,
                    output: dict["output"] as? Int ?? 0,
                    cacheRead: dict["cacheRead"] as? Int ?? 0
                )
            }
        }
        return state
    }

    /// 将扫描状态写入磁盘
    nonisolated private static func saveScanState(_ state: ScanState) {
        let daysDict = state.daysByKey.mapValues { d -> [String: Any] in
            ["date": d.date, "input": d.input, "output": d.output, "cacheRead": d.cacheRead]
        }
        let obj: [String: Any] = [
            "version": 2,
            "offsets": state.offsets,
            "days": daysDict,
            "hours": state.hoursByKey
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        try? data.write(to: stateFileURL, options: .atomic)
    }

    // MARK: 扫描与解析（后台线程执行，增量模式）

    /// 增量扫描：只读取每个 wire.jsonl 自上次偏移量以来的新增内容。
    /// 累计结果随状态持久化，重启后从磁盘恢复继续累加。
    /// 返回：按天用量 + 今日按小时用量（24 格，下标为小时）+ 最新扫描状态。
    nonisolated private static func scanSessionFiles() -> ([LocalUsageDay], [Int], ScanState) {
        let environment = ProcessInfo.processInfo.environment
        let root = environment["KIMI_CODE_HOME"] ?? (NSHomeDirectory() + "/.kimi-code")
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        let sessionsURL = rootURL.appendingPathComponent("sessions", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsURL,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return ([], [], loadScanState()) }

        // 从磁盘恢复上次状态
        var state = loadScanState()
        let calendar = Calendar.current
        var seenRelPaths = Set<String>()

        for case let fileURL as URL in enumerator {
            guard fileURL.lastPathComponent == "wire.jsonl",
                  fileURL.path.contains("/agents/") else { continue }

            // 计算相对于 root 的路径作为状态 key
            guard let relPath = fileURL.path.relativeTo(root) else { continue }
            seenRelPaths.insert(relPath)

            let fileSize: Int
            if let vals = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
               let s = vals.fileSize {
                fileSize = s
            } else { continue }

            let prevOffset = state.offsets[relPath] ?? 0

            // 文件大小未变 → 跳过，零 IO
            if fileSize == prevOffset { continue }

            // 文件被截断/重建（不应发生但防御性处理）→ 全量重读
            let fromOffset: Int = fileSize < prevOffset ? 0 : prevOffset

            autoreleasepool {
                guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return }
                defer { try? handle.close() }

                if fromOffset > 0 {
                    try? handle.seek(toOffset: UInt64(fromOffset))
                }
                let newData = handle.readDataToEndOfFile()
                guard !newData.isEmpty,
                      let text = String(data: newData, encoding: .utf8) else { return }

                text.enumerateLines { line, _ in
                    guard line.contains("\"usage.record\""),
                          let lineData = line.data(using: .utf8),
                          let event = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                          event["type"] as? String == "usage.record",
                          let usage = event["usage"] as? [String: Any],
                          let timeMs = (event["time"] as? NSNumber)?.doubleValue else { return }

                    let eventDate = Date(timeIntervalSince1970: timeMs / 1000)
                    let day = calendar.startOfDay(for: eventDate)
                    let key = scanDayKeyFormatter.string(from: day)
                    var entry = state.daysByKey[key] ?? LocalUsageDayCodable(
                        date: day.timeIntervalSince1970, input: 0, output: 0, cacheRead: 0
                    )
                    let cacheRead = (usage["inputCacheRead"] as? NSNumber)?.intValue ?? 0
                    let input = ((usage["inputOther"] as? NSNumber)?.intValue ?? 0)
                        + cacheRead
                        + ((usage["inputCacheCreation"] as? NSNumber)?.intValue ?? 0)
                    let output = (usage["output"] as? NSNumber)?.intValue ?? 0
                    entry.input += input
                    entry.output += output
                    entry.cacheRead += cacheRead
                    state.daysByKey[key] = entry

                    // 小时粒度（服务「今日」波浪曲线）
                    let hourKey = String(format: "%@-%02d", key, calendar.component(.hour, from: eventDate))
                    state.hoursByKey[hourKey, default: 0] += input + output
                }
            }

            // 更新偏移量
            state.offsets[relPath] = fileSize
        }

        // 清理已不存在的文件记录，防止 state 无限膨胀
        for removedKey in state.offsets.keys where !seenRelPaths.contains(removedKey) {
            state.offsets.removeValue(forKey: removedKey)
        }

        // 小时粒度只服务「今日」曲线：裁剪掉今天之前的 bucket（key 前缀 yyyy-MM-dd 可直接比较）
        let todayKey = scanDayKeyFormatter.string(from: calendar.startOfDay(for: Date()))
        state.hoursByKey = state.hoursByKey.filter { $0.key.hasPrefix(todayKey) }

        // 持久化状态
        saveScanState(state)

        // 转为 LocalUsageDay 数组
        let days = state.daysByKey.values.map { c in
            LocalUsageDay(
                date: Date(timeIntervalSince1970: c.date),
                input: c.input,
                output: c.output,
                cacheRead: c.cacheRead
            )
        }.sorted { $0.date < $1.date }

        // 今日按小时用量（24 格，下标为小时）
        var todayHours = [Int](repeating: 0, count: 24)
        for (key, tokens) in state.hoursByKey {
            if let hour = Int(key.suffix(2)), todayHours.indices.contains(hour) {
                todayHours[hour] += tokens
            }
        }

        return (days, todayHours, state)
    }
}

// MARK: - 本机消耗量卡片

/// 「本机消耗量」卡片：使用 Token 大数字 + 缓存命中率 + 按天柱状图（悬停出 tooltip）。
/// 范围三档：累计（默认）/ 今日 / 7天，选择持久化到 localUsageRange。
struct LocalUsageCard: View {
    @StateObject private var service = KimiLocalUsageService.shared
    @StateObject private var languageManager = LanguageManager.shared
    @AppStorage("localUsageRange") private var rangeRaw: String = LocalUsageRange.all.rawValue
    @State private var hoveredDay: LocalUsageDay?
    @State private var hoveredSegment: LocalUsageRange?
    @State private var hoveredHourIndex: Int?
    @State private var shimmerPhase: CGFloat = -1

    private let chartHeight: CGFloat = 44
    private let tooltipZoneHeight: CGFloat = 26

    private static let monthDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd"
        return formatter
    }()

    private var range: LocalUsageRange {
        LocalUsageRange(rawValue: rangeRaw) ?? .all
    }

    private var filteredDays: [LocalUsageDay] {
        service.days(in: range)
    }

    /// 首次扫描进行中（尚未拿到任何结果）：整张卡片内容区展示骨架屏；
    /// 后续刷新复用上次结果，不闪烁。
    private var isLoadingFirstTime: Bool {
        service.isLoading && !service.hasScanned
    }

    /// 图表展示的天数：
    /// - 累计档：近 30 个自然日（全历史柱子太密），大数字仍按全量累计
    /// - 7天档：固定 7 根柱子（今天往前 6 天），缺失的天补 0 值占位，避免只显示几根
    /// - 今日档：由 todayWaveChart 处理，不走此处
    private var chartDays: [LocalUsageDay] {
        switch range {
        case .all:
            let calendar = Calendar.current
            let start = calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: Date())) ?? .distantPast
            return filteredDays.filter { $0.date >= start }
        case .week:
            // 固定 7 根柱子：缺失的天补 0 值占位，柱状图始终对齐 7 天
            let calendar = Calendar.current
            let todayStart = calendar.startOfDay(for: Date())
            return (0..<7).reversed().map { offset in
                let date = calendar.date(byAdding: .day, value: -offset, to: todayStart)!
                if let day = filteredDays.first(where: { $0.date == date }) {
                    return day
                }
                return LocalUsageDay(date: date, input: 0, output: 0, cacheRead: 0)
            }
        case .today:
            return filteredDays
        }
    }

    /// 指标标签随范围联动：累计使用 Token / 今日使用 Token / 7 天使用 Token
    private var metricsLabelKey: String {
        switch range {
        case .all: return "累计使用 Token"
        case .today: return "今日使用 Token"
        case .week: return "7 天使用 Token"
        }
    }

    private var totalTokens: Int {
        filteredDays.reduce(0) { $0 + $1.totalTokens }
    }

    /// 所选范围无记录时命中率为 nil（显示 --）
    private var cacheHitRate: Double? {
        let input = filteredDays.reduce(0) { $0 + $1.input }
        guard input > 0 else { return nil }
        let cacheRead = filteredDays.reduce(0) { $0 + $1.cacheRead }
        return Double(cacheRead) / Double(input)
    }

    private var maxDayTokens: Int {
        chartDays.map(\.totalTokens).max() ?? 0
    }

    private var formattedTokens: (value: String, unit: String) {
        KimiLocalUsageService.formatTokenCount(totalTokens)
    }

    private var cacheHitRateText: String {
        guard let cacheHitRate else { return "--" }
        return String(format: "%.1f%%", cacheHitRate * 100)
    }

    /// 柱子密度随根数调整：累计（几十根）用窄柱密排，7天/今日用宽柱
    private var barSpacing: CGFloat { chartDays.count > 20 ? 2 : 6 }
    private var barCornerRadius: CGFloat { chartDays.count > 20 ? 1 : 3 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerRow
            if isLoadingFirstTime {
                // 首次扫描：内容区整体骨架（大数字 + 图表），避免 0 值闪现
                metricsSkeleton
                    .modifier(SkeletonShimmer(phase: shimmerPhase))
                chartSkeleton
                    .modifier(SkeletonShimmer(phase: shimmerPhase))
                    .onAppear {
                        withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                            shimmerPhase = 1
                        }
                    }
            } else {
                metricsRow
                chartArea
            }
        }
        .padding(14)
        .background(Color.kimiCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: 标题 + 范围切换

    private var headerRow: some View {
        HStack {
            LText("本机消耗量")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.kimiTextPrimary)

            Spacer()

            rangePicker
        }
    }

    private var rangePicker: some View {
        HStack(spacing: 2) {
            ForEach(LocalUsageRange.allCases) { item in
                let isSelected = range == item
                let isHovered = hoveredSegment == item
                Text(item.displayName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isSelected ? Color.white : (isHovered ? Color.kimiTextPrimary : Color.kimiTextSecondary))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule()
                            .fill(isSelected ? Color.kimiBlue : Color.kimiTextPrimary.opacity(isHovered ? 0.08 : 0))
                    )
                    .contentShape(Capsule())
                    .onTapGesture { rangeRaw = item.rawValue }
                    .onHover { hoveredSegment = $0 ? item : nil }
                    .cursor(.pointingHand)
            }
        }
        .padding(2)
        .background(Color.kimiTextPrimary.opacity(0.06))
        .clipShape(Capsule())
    }

    // MARK: 指标行（使用 Token + 缓存命中率）

    private var metricsRow: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .lastTextBaseline, spacing: 2) {
                    Text(formattedTokens.value)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.kimiTextPrimary)
                    if !formattedTokens.unit.isEmpty {
                        Text(formattedTokens.unit)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.kimiTextPrimary)
                    }
                }

                LText(metricsLabelKey)
                    .font(.system(size: 11))
                    .foregroundStyle(.kimiTextTertiary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(cacheHitRateText)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Color.green)

                LText("缓存命中率")
                    .font(.system(size: 11))
                    .foregroundStyle(.kimiTextTertiary)
            }
        }
    }

    // MARK: 柱状图（按天，悬停出 tooltip）

    @ViewBuilder
    private var chartArea: some View {
        if filteredDays.isEmpty {
            // 空态：所选范围完全无记录（大数字同为 0，口径一致）
            LText("暂无会话记录")
                .font(.system(size: 13))
                .foregroundStyle(.kimiTextTertiary)
                .frame(maxWidth: .infinity)
                .frame(height: chartHeight + tooltipZoneHeight)
        } else if chartDays.isEmpty {
            // 仅累计档可能出现：历史有记录但近 30 天无记录
            LText("近 30 天暂无记录")
                .font(.system(size: 13))
                .foregroundStyle(.kimiTextTertiary)
                .frame(maxWidth: .infinity)
                .frame(height: chartHeight + tooltipZoneHeight)
        } else if range == .today {
            todayWaveChart
        } else {
            barChart
        }
    }

    // MARK: 骨架屏（首次扫描未完成时展示，结构与 metricsRow / barChart 对齐）

    /// 与 metricsRow 布局一致：左侧大数字占位 + 右侧命中率占位
    private var metricsSkeleton: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                skeletonBlock(width: 84, height: 22)
                skeletonBlock(width: 60, height: 12)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                skeletonBlock(width: 50, height: 22)
                skeletonBlock(width: 48, height: 12)
            }
        }
    }

    /// 与 barChart 占位高度一致
    private var chartSkeleton: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.kimiTextPrimary.opacity(0.08))
            .frame(height: chartHeight + tooltipZoneHeight)
    }

    private func skeletonBlock(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Color.kimiTextPrimary.opacity(0.10))
            .frame(width: width, height: height)
    }

    private var barChart: some View {
        GeometryReader { proxy in
            let count = chartDays.count
            let slotWidth = proxy.size.width / CGFloat(count)
            // 柱子最大 22px，避免 7 根柱子时过宽；密集档（累计）按槽位宽度收窄
            let barWidth = min(slotWidth - barSpacing, 22)
            let chartBottomY = chartHeight + tooltipZoneHeight

            ZStack(alignment: .bottom) {
                // 柱子 + 柱顶圆点
                ForEach(Array(chartDays.enumerated()), id: \.element.id) { index, day in
                    let centerX = slotWidth * (CGFloat(index) + 0.5)
                    let height = barHeight(for: day)
                    let topY = chartBottomY - height

                    // 柱子（渐变填充）
                    RoundedRectangle(cornerRadius: barCornerRadius)
                        .fill(barGradient(for: day))
                        .frame(width: barWidth, height: height)
                        .position(x: centerX, y: chartBottomY - height / 2)
                        .onHover { isHovered in
                            hoveredDay = isHovered ? day : nil
                        }

                    // 柱顶圆点
                    Circle()
                        .fill(Color.kimiBlue)
                        .frame(width: 5, height: 5)
                        .overlay(Circle().stroke(Color.kimiCardBackground, lineWidth: 1.2))
                        .position(x: centerX, y: topY)
                }

                // 折线（连接各柱顶，展示趋势）
                if count > 1 {
                    Path { path in
                        for (index, day) in chartDays.enumerated() {
                            let centerX = slotWidth * (CGFloat(index) + 0.5)
                            let y = chartBottomY - barHeight(for: day)
                            if index == 0 {
                                path.move(to: CGPoint(x: centerX, y: y))
                            } else {
                                path.addLine(to: CGPoint(x: centerX, y: y))
                            }
                        }
                    }
                    .stroke(Color.kimiBlue.opacity(0.45), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                }

                if let hoveredDay {
                    tooltipView(for: hoveredDay)
                        .position(tooltipPosition(for: hoveredDay, in: proxy.size))
                }
            }
        }
        .frame(height: chartHeight + tooltipZoneHeight)
    }

    private func barHeight(for day: LocalUsageDay) -> CGFloat {
        guard maxDayTokens > 0 else { return 2 }
        // 0 值天保留 2px 占位，让柱子轮廓可见（7天档缺失天也能看出柱子）
        if day.totalTokens == 0 { return 2 }
        return max(2, CGFloat(day.totalTokens) / CGFloat(maxDayTokens) * chartHeight)
    }

    private func barGradient(for day: LocalUsageDay) -> LinearGradient {
        let isHovered = hoveredDay?.id == day.id
        let topColor: Color = isHovered ? .kimiBlue : .kimiBlue.opacity(0.55)
        let bottomColor: Color = isHovered ? .kimiBlue.opacity(0.7) : .kimiBlue.opacity(0.15)
        return LinearGradient(
            colors: [topColor, bottomColor],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private func tooltipView(for day: LocalUsageDay) -> some View {
        let formatted = KimiLocalUsageService.formatTokenCount(day.totalTokens)
        let dateText = Self.monthDayFormatter.string(from: day.date)
        return VStack(spacing: 0) {
            Text("\(dateText) · \(formatted.value)\(formatted.unit)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.kimiTextPrimary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.kimiPanelBackground)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(Color.kimiTextPrimary.opacity(0.15), lineWidth: 0.5)
                )

            TooltipTriangle()
                .fill(Color.kimiPanelBackground)
                .frame(width: 10, height: 5)
        }
    }

    private func tooltipPosition(for day: LocalUsageDay, in size: CGSize) -> CGPoint {
        let count = chartDays.count
        let index = chartDays.firstIndex(where: { $0.id == day.id }) ?? 0
        let centerX = size.width * (CGFloat(index) + 0.5) / CGFloat(max(count, 1))
        // tooltip 宽约 96，clamp 防止贴边时超出卡片
        let clampedX = min(max(centerX, 48), size.width - 48)
        return CGPoint(x: clampedX, y: tooltipZoneHeight / 2)
    }

    // MARK: 今日波浪曲线（按小时，股市风格面积图）

    /// 今日曲线数据点：0 点到当前小时（未来小时不画）
    private var todayChartPoints: [(hour: Int, tokens: Int)] {
        let currentHour = Calendar.current.component(.hour, from: Date())
        return (0...currentHour).map { hour in
            (hour, hour < service.todayHours.count ? service.todayHours[hour] : 0)
        }
    }

    private var todayWaveChart: some View {
        GeometryReader { proxy in
            let points = todayChartPoints
            let maxTokens = max(points.map(\.tokens).max() ?? 0, 1)
            // 曲线绘制区在顶部 tooltip 区之下
            let chartRect = CGRect(x: 0, y: tooltipZoneHeight, width: proxy.size.width, height: chartHeight)
            let coords = todayCurveCoords(points: points, maxTokens: maxTokens, in: chartRect)

            ZStack(alignment: .topLeading) {
                // 曲线下方蓝色面积渐变
                todayAreaPath(coords: coords, in: chartRect)
                    .fill(
                        LinearGradient(
                            colors: [Color.kimiBlue.opacity(0.30), Color.kimiBlue.opacity(0.02)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                // 蓝色平滑曲线
                smoothedLinePath(coords)
                    .stroke(Color.kimiBlue, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

                if let hovered = hoveredHourIndex, coords.indices.contains(hovered) {
                    let point = coords[hovered]
                    // 垂直指示线 + 数据点
                    Path { path in
                        path.move(to: CGPoint(x: point.x, y: chartRect.minY))
                        path.addLine(to: CGPoint(x: point.x, y: chartRect.maxY))
                    }
                    .stroke(Color.kimiBlue.opacity(0.35), lineWidth: 1)

                    Circle()
                        .fill(Color.kimiBlue)
                        .frame(width: 7, height: 7)
                        .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: 1.5))
                        .position(point)

                    hourTooltipView(hour: points[hovered].hour, tokens: points[hovered].tokens)
                        .position(hourTooltipPosition(for: hovered, in: proxy.size))
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let location):
                    guard !coords.isEmpty else { return }
                    let step = proxy.size.width / CGFloat(max(coords.count - 1, 1))
                    hoveredHourIndex = min(max(Int((location.x / step).rounded()), 0), coords.count - 1)
                case .ended:
                    hoveredHourIndex = nil
                }
            }
        }
        .frame(height: chartHeight + tooltipZoneHeight)
    }

    /// 数据点 → 曲线坐标（x 均分，y 按最大值归一，底部对齐）
    private func todayCurveCoords(points: [(hour: Int, tokens: Int)], maxTokens: Int, in rect: CGRect) -> [CGPoint] {
        points.enumerated().map { index, point in
            let x = points.count > 1
                ? rect.width * CGFloat(index) / CGFloat(points.count - 1)
                : rect.midX
            let y = rect.maxY - CGFloat(point.tokens) / CGFloat(maxTokens) * rect.height
            return CGPoint(x: x, y: y)
        }
    }

    /// Catmull-Rom 平滑曲线（经过每个数据点的波浪效果）
    private func smoothedLinePath(_ coords: [CGPoint]) -> Path {
        var path = Path()
        guard let first = coords.first else { return path }
        guard coords.count > 1 else {
            // 只有一个数据点（刚过 0 点）：画一小段横线避免空白
            path.move(to: CGPoint(x: first.x - 2, y: first.y))
            path.addLine(to: CGPoint(x: first.x + 2, y: first.y))
            return path
        }
        path.move(to: first)
        for index in 0..<(coords.count - 1) {
            let p0 = coords[max(index - 1, 0)]
            let p1 = coords[index]
            let p2 = coords[index + 1]
            let p3 = coords[min(index + 2, coords.count - 1)]
            let control1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let control2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: control1, control2: control2)
        }
        return path
    }

    /// 曲线下方闭合区域（面积填充）
    private func todayAreaPath(coords: [CGPoint], in rect: CGRect) -> Path {
        var path = smoothedLinePath(coords)
        guard let first = coords.first, let last = coords.last else { return path }
        path.addLine(to: CGPoint(x: last.x, y: rect.maxY))
        path.addLine(to: CGPoint(x: first.x, y: rect.maxY))
        path.closeSubpath()
        return path
    }

    private func hourTooltipView(hour: Int, tokens: Int) -> some View {
        let formatted = KimiLocalUsageService.formatTokenCount(tokens)
        return VStack(spacing: 0) {
            Text(String(format: "%02d:00 · %@%@", hour, formatted.value, formatted.unit))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.kimiTextPrimary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.kimiPanelBackground)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(Color.kimiTextPrimary.opacity(0.15), lineWidth: 0.5)
                )

            TooltipTriangle()
                .fill(Color.kimiPanelBackground)
                .frame(width: 10, height: 5)
        }
    }

    private func hourTooltipPosition(for index: Int, in size: CGSize) -> CGPoint {
        let count = todayChartPoints.count
        let centerX = count > 1
            ? size.width * CGFloat(index) / CGFloat(count - 1)
            : size.width / 2
        // tooltip 宽约 96，clamp 防止贴边时超出卡片
        let clampedX = min(max(centerX, 48), size.width - 48)
        return CGPoint(x: clampedX, y: tooltipZoneHeight / 2)
    }
}

/// 路径辅助：计算相对于 base 的路径字符串
private extension String {
    func relativeTo(_ base: String) -> String? {
        guard hasPrefix(base) else { return nil }
        let rel = String(dropFirst(base.count))
        return rel.hasPrefix("/") ? String(rel.dropFirst()) : rel
    }
}

/// tooltip 下方的小三角
private struct TooltipTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

// MARK: - 骨架屏闪光动效

/// 骨架屏 Shimmer 效果：渐变高光从左到右扫过，phase 由外部动画驱动（-1 → 1）。
private struct SkeletonShimmer: ViewModifier {
    let phase: CGFloat

    func body(content: Content) -> some View {
        content.overlay(
            GeometryReader { geo in
                LinearGradient(
                    colors: [
                        .clear,
                        Color.white.opacity(0.18),
                        .clear
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: geo.size.width * 0.5)
                .offset(x: (phase + 1) / 2 * (geo.size.width + geo.size.width * 0.5) - geo.size.width * 0.25)
                .blendMode(.plusLighter)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
