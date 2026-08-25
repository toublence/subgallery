import Charts
import SwiftUI

enum ReceiptReportRange: String, CaseIterable, Identifiable {
    case thisMonth, lastMonth, threeMonths, all, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .thisMonth: L10n.text("이번 달")
        case .lastMonth: L10n.text("지난달")
        case .threeMonths: L10n.text("최근 3개월")
        case .all: L10n.text("전체")
        case .custom: L10n.text("기간 지정")
        }
    }
}

enum ReceiptReportGrouping: String, CaseIterable, Identifiable {
    case day, week, month

    var id: String { rawValue }

    var title: String {
        switch self {
        case .day: L10n.text("일별")
        case .week: L10n.text("주별")
        case .month: L10n.text("월별")
        }
    }
}

struct ReceiptReportChartPoint: Identifiable {
    let currencyCode: String
    let date: Date
    let value: Decimal

    var id: String { "\(currencyCode)-\(date.timeIntervalSinceReferenceDate)" }
}

struct ReceiptMerchantStat: Identifiable {
    let key: String
    let merchant: String
    let currencyCode: String
    let total: Decimal
    let count: Int

    var id: String { "\(key)\u{1F}\(currencyCode)" }
    var amount: ReceiptAmount { ReceiptAmount(currencyCode: currencyCode, value: total) }
}

struct ReceiptRankedItem: Identifiable {
    let item: MediaItem
    let amount: ReceiptAmount

    var id: UUID { item.id }
}

struct ReceiptDayStat: Identifiable {
    let currencyCode: String
    let date: Date
    let total: Decimal
    let items: [MediaItem]

    var id: String { "\(currencyCode)-\(date.timeIntervalSinceReferenceDate)" }
    var amount: ReceiptAmount { ReceiptAmount(currencyCode: currencyCode, value: total) }
}

struct ReceiptCurrencyReport: Identifiable {
    let currencyCode: String
    let total: Decimal
    let count: Int
    let average: Decimal
    let maximum: Decimal
    let chartPoints: [ReceiptReportChartPoint]
    let frequentMerchants: [ReceiptMerchantStat]
    let spendingMerchants: [ReceiptMerchantStat]
    let largestReceipts: [ReceiptRankedItem]
    let biggestDay: ReceiptDayStat?

    var id: String { currencyCode }
    var totalAmount: ReceiptAmount { ReceiptAmount(currencyCode: currencyCode, value: total) }
    var averageAmount: ReceiptAmount { ReceiptAmount(currencyCode: currencyCode, value: average) }
    var maximumAmount: ReceiptAmount { ReceiptAmount(currencyCode: currencyCode, value: maximum) }
}

struct ReceiptReportAnalytics {
    let receiptCount: Int
    let currencyReports: [ReceiptCurrencyReport]
    let frequentMerchants: [ReceiptMerchantStat]
    let unreadableReceipts: [MediaItem]

    var hasReadableAmounts: Bool { !currencyReports.isEmpty }
}

enum ReceiptReportAnalyticsService {
    private struct ParsedEntry {
        let item: MediaItem
        let amount: ReceiptAmount
    }

    static func build(
        items: [MediaItem],
        grouping: ReceiptReportGrouping,
        calendar: Calendar = .current,
        locale: Locale = AppLanguage.selected.locale
    ) -> ReceiptReportAnalytics {
        let parsed = items.compactMap { item in
            ReceiptSummaryService.amount(for: item, locale: locale).map {
                ParsedEntry(item: item, amount: $0)
            }
        }
        let unreadable = items.filter {
            ReceiptSummaryService.amount(for: $0, locale: locale) == nil
        }
        let byCurrency = Dictionary(grouping: parsed, by: { $0.amount.currencyCode })
        let reports = byCurrency.map { currencyCode, entries in
            currencyReport(
                currencyCode: currencyCode,
                entries: entries,
                grouping: grouping,
                calendar: calendar
            )
        }
        .sorted { $0.currencyCode < $1.currencyCode }

        let frequent = reports.flatMap(\.frequentMerchants).sorted {
            if $0.count != $1.count { return $0.count > $1.count }
            if $0.total != $1.total { return $0.total > $1.total }
            return $0.merchant.localizedStandardCompare($1.merchant) == .orderedAscending
        }

        return ReceiptReportAnalytics(
            receiptCount: items.count,
            currencyReports: reports,
            frequentMerchants: frequent,
            unreadableReceipts: unreadable
        )
    }

    private static func currencyReport(
        currencyCode: String,
        entries: [ParsedEntry],
        grouping: ReceiptReportGrouping,
        calendar: Calendar
    ) -> ReceiptCurrencyReport {
        let total = entries.reduce(Decimal.zero) { $0 + $1.amount.value }
        let average = entries.isEmpty ? 0 : total / Decimal(entries.count)
        let maximum = entries.map(\.amount.value).max() ?? 0
        let merchantStats = merchants(currencyCode: currencyCode, entries: entries)

        let chartGroups = Dictionary(grouping: entries) {
            bucketDate(for: $0.item.receiptDisplayDate, grouping: grouping, calendar: calendar)
        }
        let chartPoints = chartGroups.map { date, values in
            ReceiptReportChartPoint(
                currencyCode: currencyCode,
                date: date,
                value: values.reduce(0) { $0 + $1.amount.value }
            )
        }
        .sorted { $0.date < $1.date }

        let dayGroups = Dictionary(grouping: entries) {
            calendar.startOfDay(for: $0.item.receiptDisplayDate)
        }
        let biggestDay = dayGroups.map { date, values in
            ReceiptDayStat(
                currencyCode: currencyCode,
                date: date,
                total: values.reduce(0) { $0 + $1.amount.value },
                items: values.map(\.item).sorted { $0.receiptDisplayDate > $1.receiptDisplayDate }
            )
        }
        .max {
            if $0.total != $1.total { return $0.total < $1.total }
            return $0.date < $1.date
        }

        let largest = entries.sorted {
            if $0.amount.value != $1.amount.value { return $0.amount.value > $1.amount.value }
            return $0.item.receiptDisplayDate > $1.item.receiptDisplayDate
        }
        .prefix(5)
        .map { ReceiptRankedItem(item: $0.item, amount: $0.amount) }

        return ReceiptCurrencyReport(
            currencyCode: currencyCode,
            total: total,
            count: entries.count,
            average: average,
            maximum: maximum,
            chartPoints: chartPoints,
            frequentMerchants: merchantStats.sorted {
                if $0.count != $1.count { return $0.count > $1.count }
                return $0.total > $1.total
            },
            spendingMerchants: merchantStats.sorted {
                if $0.total != $1.total { return $0.total > $1.total }
                return $0.count > $1.count
            },
            largestReceipts: largest,
            biggestDay: biggestDay
        )
    }

    private static func merchants(
        currencyCode: String,
        entries: [ParsedEntry]
    ) -> [ReceiptMerchantStat] {
        var values: [String: (name: String, total: Decimal, count: Int)] = [:]
        for entry in entries {
            guard let merchant = normalizedMerchant(entry.item.receiptMerchant) else { continue }
            var value = values[merchant.key] ?? (merchant.display, 0, 0)
            value.total += entry.amount.value
            value.count += 1
            values[merchant.key] = value
        }
        return values.map { key, value in
            ReceiptMerchantStat(
                key: key,
                merchant: value.name,
                currencyCode: currencyCode,
                total: value.total,
                count: value.count
            )
        }
    }

    static func normalizedMerchant(_ raw: String) -> (key: String, display: String)? {
        let display = raw
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !display.isEmpty else { return nil }
        let key = display.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: AppLanguage.selected.locale
        )
        return (key, display)
    }

    private static func bucketDate(
        for date: Date,
        grouping: ReceiptReportGrouping,
        calendar: Calendar
    ) -> Date {
        switch grouping {
        case .day:
            calendar.startOfDay(for: date)
        case .week:
            calendar.dateInterval(of: .weekOfYear, for: date)?.start
                ?? calendar.startOfDay(for: date)
        case .month:
            calendar.dateInterval(of: .month, for: date)?.start
                ?? calendar.startOfDay(for: date)
        }
    }
}

private struct ReceiptReportSelection: Identifiable {
    let id = UUID()
    let title: String
    let items: [MediaItem]
}

struct ReceiptReportView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @StateObject private var purchases = PurchaseManager.shared
    let receipts: [MediaItem]

    @AppStorage("receipt.report.range") private var rangeRaw = ReceiptReportRange.thisMonth.rawValue
    @State private var customStart = Calendar.current.date(byAdding: .month, value: -1, to: .now) ?? .now
    @State private var customEnd = Date.now
    @State private var detailItem: MediaItem?
    @State private var viewerItem: MediaItem?
    @State private var selection: ReceiptReportSelection?
    @State private var consumedThisSession = false
    @State private var remainingFreeUses = ReceiptReportTrialPolicy.freeUseLimit
    @State private var loggedRenderTokens = Set<String>()

    private var range: ReceiptReportRange {
        ReceiptReportRange(rawValue: rangeRaw) ?? .thisMonth
    }

    private var interval: DateInterval {
        let calendar = Calendar.current
        let now = Date.now
        switch range {
        case .thisMonth:
            return calendar.dateInterval(of: .month, for: now)
                ?? DateInterval(start: now, duration: 1)
        case .lastMonth:
            let previous = calendar.date(byAdding: .month, value: -1, to: now) ?? now
            return calendar.dateInterval(of: .month, for: previous)
                ?? DateInterval(start: previous, duration: 1)
        case .threeMonths:
            let current = calendar.dateInterval(of: .month, for: now)
                ?? DateInterval(start: now, duration: 1)
            let start = calendar.date(byAdding: .month, value: -2, to: current.start) ?? current.start
            return DateInterval(start: start, end: current.end)
        case .all:
            let dates = receipts.map(\.receiptDisplayDate)
            let start = calendar.startOfDay(for: dates.min() ?? now)
            let lastDay = calendar.startOfDay(for: dates.max() ?? now)
            let end = calendar.date(byAdding: .day, value: 1, to: lastDay) ?? now
            return DateInterval(start: start, end: max(end, start.addingTimeInterval(1)))
        case .custom:
            let start = calendar.startOfDay(for: min(customStart, customEnd))
            let lastDay = calendar.startOfDay(for: max(customStart, customEnd))
            let end = calendar.date(byAdding: .day, value: 1, to: lastDay) ?? lastDay
            return DateInterval(start: start, end: end)
        }
    }

    private var items: [MediaItem] {
        receipts.filter { interval.contains($0.receiptDisplayDate) }
    }

    private var grouping: ReceiptReportGrouping {
        switch range {
        case .thisMonth, .lastMonth: .day
        case .threeMonths, .all: .month
        case .custom:
            if interval.duration <= 45 * 86_400 { .day }
            else if interval.duration <= 150 * 86_400 { .week }
            else { .month }
        }
    }

    private var analytics: ReceiptReportAnalytics {
        ReceiptReportAnalyticsService.build(items: items, grouping: grouping)
    }

    private var previousSummary: ReceiptSummary? {
        guard let previous = previousInterval else { return nil }
        return ReceiptSummaryService.summary(
            for: receipts.filter { previous.contains($0.receiptDisplayDate) }
        )
    }

    private var previousInterval: DateInterval? {
        let calendar = Calendar.current
        switch range {
        case .thisMonth, .lastMonth:
            let date = calendar.date(byAdding: .month, value: -1, to: interval.start) ?? interval.start
            return calendar.dateInterval(of: .month, for: date)
        case .threeMonths:
            let start = calendar.date(byAdding: .month, value: -3, to: interval.start)
                ?? interval.start.addingTimeInterval(-interval.duration)
            return DateInterval(start: start, end: interval.start)
        case .custom:
            return DateInterval(
                start: interval.start.addingTimeInterval(-interval.duration),
                duration: interval.duration
            )
        case .all:
            return nil
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    periodSection

                    if receipts.isEmpty {
                        emptyState
                    } else if items.isEmpty {
                        noDataInPeriod
                    } else {
                        headline
                        keyMetrics
                        compactSpendingTrend
                        analysisOverview
                        spendingInsights
                        trialStatus
                    }
                }
                .frame(maxWidth: 760)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(L10n.text("지출 리포트"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("완료")) { dismiss() }
                }
            }
        }
        .onAppear {
            remainingFreeUses = ReceiptReportUsageStore.remaining
        }
        .task(id: reportRenderToken) {
            if !items.isEmpty, loggedRenderTokens.insert(reportRenderToken).inserted {
                SubGalleryAnalytics.receiptReportRendered(range: analyticsRange)
            }
            guard !consumedThisSession, !purchases.isPremium, !items.isEmpty else { return }
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            consumeFreeUseAfterRender()
        }
        .sheet(item: $detailItem) { item in
            ReceiptDetailView(item: item) { viewerItem = item }
        }
        .sheet(item: $selection) { selection in
            ReceiptReportSelectionView(selection: selection) { item in
                self.selection = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    detailItem = item
                }
            }
        }
        .fullScreenCover(item: $viewerItem) { item in
            MediaViewer(items: items, initialID: item.id, isRecentlyDeleted: false)
        }
    }

    private var periodSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Menu {
                Picker(L10n.text("기간"), selection: Binding(
                    get: { range },
                    set: { rangeRaw = $0.rawValue }
                )) {
                    ForEach(ReceiptReportRange.allCases) { value in
                        Text(value.title).tag(value)
                    }
                }
            } label: {
                HStack {
                    Text(range.title).font(.subheadline.weight(.semibold))
                    Image(systemName: "chevron.down").font(.caption2)
                    Spacer()
                    Text(intervalLabel).font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)

            if range == .custom {
                VStack {
                    DatePicker(L10n.text("시작"), selection: $customStart, displayedComponents: .date)
                    DatePicker(L10n.text("종료"), selection: $customEnd, displayedComponents: .date)
                }
                .font(.subheadline)
            }
        }
    }

    private var intervalLabel: String {
        let calendar = Calendar.current
        let end = calendar.date(byAdding: .day, value: -1, to: interval.end) ?? interval.end
        return "\(L10n.date(interval.start, dateStyle: .numeric, timeStyle: .omitted)) – \(L10n.date(end, dateStyle: .numeric, timeStyle: .omitted))"
    }

    private var headline: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L10n.format("%@ 지출", range.title))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            if analytics.hasReadableAmounts {
                ForEach(analytics.currencyReports, id: \.currencyCode) { (report: ReceiptCurrencyReport) in
                    Text(report.totalAmount.formatted())
                        .font(.system(.largeTitle, design: .rounded).weight(.bold))
                }
            } else {
                Text(L10n.text("금액 확인 필요"))
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                    .foregroundStyle(.secondary)
            }
            Text(headlineDetail)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 2)
        .padding(.vertical, 2)
    }

    private var headlineDetail: String {
        let count = L10n.format("총 %d건", analytics.receiptCount)
        if let comparison = changeDescription {
            return "\(count) · \(comparison)"
        }
        if previousInterval != nil, previousSummary?.totals.isEmpty != false {
            return "\(count) · \(L10n.text("지난 기간 데이터 없음"))"
        }
        return count
    }

    private var changeDescription: String? {
        guard analytics.currencyReports.count == 1,
              let current = analytics.currencyReports.first,
              let previousSummary,
              previousSummary.totals.count == 1,
              let previous = previousSummary.totals.first,
              previous.currencyCode == current.currencyCode,
              previous.value > 0 else { return nil }
        let difference = current.total - previous.value
        let amount = ReceiptAmount(currencyCode: current.currencyCode, value: abs(difference)).formatted()
        let percentage = NSDecimalNumber(decimal: abs(difference / previous.value) * 100).doubleValue
        let percent = String(format: "%.1f%%", locale: AppLanguage.selected.locale, percentage)
        let comparison = "\(amount) · \(percent)"
        if difference == 0 { return L10n.text("지난 기간과 동일") }
        return difference > 0
            ? L10n.format("지난 기간보다 %@ 증가", comparison)
            : L10n.format("지난 기간보다 %@ 감소", comparison)
    }

    private var primaryReport: ReceiptCurrencyReport? {
        analytics.currencyReports.count == 1 ? analytics.currencyReports.first : nil
    }

    private var primarySpendingMerchant: ReceiptMerchantStat? {
        return primaryReport?.spendingMerchants.first
    }

    private var primaryFrequentMerchant: ReceiptMerchantStat? {
        primaryReport?.frequentMerchants.first
    }

    private var keyMetricColumns: [GridItem] {
        let count = horizontalSizeClass == .regular ? 4 : 2
        return Array(repeating: GridItem(.flexible(), spacing: 8), count: count)
    }

    private var keyMetrics: some View {
        LazyVGrid(columns: keyMetricColumns, spacing: 8) {
            CompactReportMetric(title: L10n.text("평균 결제")) {
                amountValues(analytics.currencyReports.map(\.averageAmount))
            }

            if let largest = primaryReport?.largestReceipts.first {
                NavigationLink {
                    ReceiptLargestPaymentsView(reports: analytics.currencyReports)
                } label: {
                    CompactReportMetric(title: L10n.text("가장 큰 결제")) {
                        Text(largest.amount.formatted())
                        Text(merchantName(largest.item))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            } else {
                CompactReportMetric(title: L10n.text("가장 큰 결제")) {
                    amountValues(analytics.currencyReports.map(\.maximumAmount))
                }
            }

            if let merchant = primarySpendingMerchant {
                NavigationLink {
                    ReceiptMerchantAnalysisView(reports: analytics.currencyReports)
                } label: {
                    CompactReportMetric(title: L10n.text("가장 많이 쓴 곳")) {
                        Text(merchant.merchant)
                        Text("\(merchant.amount.formatted()) · \(merchantShare(merchant))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            } else {
                CompactReportMetric(title: L10n.text("가장 많이 쓴 곳")) {
                    Text("—").foregroundStyle(.secondary)
                }
            }

            if let merchant = primaryFrequentMerchant {
                NavigationLink {
                    ReceiptMerchantAnalysisView(reports: analytics.currencyReports)
                } label: {
                    CompactReportMetric(title: L10n.text("가장 많이 방문")) {
                        Text(merchant.merchant)
                        Text(L10n.format("%d회", merchant.count))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            } else {
                CompactReportMetric(title: L10n.text("가장 많이 방문")) {
                    Text("—").foregroundStyle(.secondary)
                }
            }
        }
    }

    private func merchantShare(_ merchant: ReceiptMerchantStat) -> String {
        guard let total = primaryReport?.total, total > 0 else { return "" }
        return L10n.format("전체의 %@", percentage(merchant.total / total))
    }

    @ViewBuilder
    private func amountValues(_ amounts: [ReceiptAmount]) -> some View {
        if amounts.isEmpty {
            Text("—").foregroundStyle(.secondary)
        } else {
            ForEach(Array(amounts.enumerated()), id: \.offset) { _, amount in
                Text(amount.formatted()).lineLimit(1).minimumScaleFactor(0.75)
            }
        }
    }

    private var showsCompactTrend: Bool {
        analytics.receiptCount >= 2
            && analytics.currencyReports.contains { !$0.chartPoints.isEmpty }
    }

    @ViewBuilder
    private var compactSpendingTrend: some View {
        if showsCompactTrend {
            NavigationLink {
                SpendingTrendDetailView(receipts: items)
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label(L10n.text("지출 흐름"), systemImage: "chart.bar.xaxis")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    ForEach(analytics.currencyReports) { report in
                        if !report.chartPoints.isEmpty {
                            if analytics.currencyReports.count > 1 {
                                Text(report.currencyCode)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            Chart(report.chartPoints) { point in
                                BarMark(
                                    x: .value(L10n.text("날짜"), point.date),
                                    y: .value(L10n.text("금액"), point.value.doubleValue)
                                )
                                .foregroundStyle(Color.accentColor.gradient)
                                .cornerRadius(2)
                            }
                            .chartXAxis {
                                AxisMarks(values: .automatic(desiredCount: 4)) {
                                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                                }
                            }
                            .chartYAxis(.hidden)
                            .frame(height: analytics.currencyReports.count == 1 ? 112 : 76)
                        }
                    }
                }
                .padding(12)
                .background(.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var analysisOverview: some View {
        if hasMerchantSummary, hasLargePayments, horizontalSizeClass == .regular {
            HStack(alignment: .top, spacing: 10) {
                merchantSummaryCard
                largestPaymentsCard
            }
        } else if hasMerchantSummary, hasLargePayments {
            VStack(spacing: 10) {
                merchantSummaryCard
                largestPaymentsCard
            }
        } else if hasMerchantSummary {
            merchantSummaryCard
        } else if hasLargePayments {
            largestPaymentsCard
        }
    }

    private var hasMerchantSummary: Bool {
        analytics.currencyReports.contains { !$0.spendingMerchants.isEmpty }
    }

    private var hasLargePayments: Bool {
        analytics.currencyReports.contains { !$0.largestReceipts.isEmpty }
    }

    private var merchantSummaryCard: some View {
        NavigationLink {
            ReceiptMerchantAnalysisView(reports: analytics.currencyReports)
        } label: {
            dashboardSection(title: L10n.text("상호별 지출"), symbol: "building.2") {
                ForEach(analytics.currencyReports) { report in
                    if analytics.currencyReports.count > 1 {
                        Text(report.currencyCode)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(report.spendingMerchants.prefix(3).enumerated()), id: \.element.id) { index, merchant in
                        summaryRow(
                            title: "\(index + 1). \(merchant.merchant)",
                            value: merchant.amount.formatted()
                        )
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var largestPaymentsCard: some View {
        NavigationLink {
            ReceiptLargestPaymentsView(reports: analytics.currencyReports)
        } label: {
            dashboardSection(title: "\(L10n.text("큰 결제")) TOP 3", symbol: "creditcard") {
                ForEach(analytics.currencyReports) { report in
                    if analytics.currencyReports.count > 1 {
                        Text(report.currencyCode)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(report.largestReceipts.prefix(3).enumerated()), id: \.element.id) { index, ranked in
                        summaryRow(
                            title: "\(index + 1). \(merchantName(ranked.item))",
                            value: ranked.amount.formatted()
                        )
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func dashboardSection<Content: View>(
        title: String,
        symbol: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label(title, systemImage: symbol)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 140, alignment: .topLeading)
        .background(.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func summaryRow(title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.subheadline)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(value)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }

    @ViewBuilder
    private var spendingInsights: some View {
        let lines = calculatedInsightLines
        if primaryReport?.biggestDay != nil || !lines.isEmpty || !analytics.unreadableReceipts.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Label(L10n.text("지출 인사이트"), systemImage: "sparkles")
                    .font(.subheadline.weight(.semibold))
                    .padding(.vertical, 11)

                if let day = primaryReport?.biggestDay {
                    Divider()
                    Button {
                        selection = ReceiptReportSelection(
                            title: L10n.date(day.date, dateStyle: .long, timeStyle: .omitted),
                            items: day.items
                        )
                    } label: {
                        highlightRow(
                            symbol: "calendar",
                            title: L10n.text("가장 많이 쓴 날"),
                            value: "\(L10n.date(day.date, dateStyle: .abbreviated, timeStyle: .omitted)) · \(day.amount.formatted())"
                        )
                    }
                    .buttonStyle(.plain)
                }

                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Divider()
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: "chart.pie")
                            .font(.caption)
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 18)
                        Text(line)
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 10)
                }

                if !analytics.unreadableReceipts.isEmpty {
                    Divider()
                    Button {
                        selection = ReceiptReportSelection(
                            title: L10n.text("확인 필요한 영수증"),
                            items: analytics.unreadableReceipts
                        )
                    } label: {
                        highlightRow(
                            symbol: "exclamationmark.circle",
                            title: L10n.text("확인 필요"),
                            value: L10n.format("%d건", analytics.unreadableReceipts.count)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .background(.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private var calculatedInsightLines: [String] {
        guard let report = primaryReport, report.total > 0 else { return [] }
        var values: [String] = []

        if let merchant = report.spendingMerchants.first {
            values.append(L10n.format(
                "전체 지출의 %@가 %@에서 발생",
                percentage(merchant.total / report.total),
                merchant.merchant
            ))
        }

        if report.count >= 4 {
            let topThree = report.largestReceipts.prefix(3).reduce(Decimal.zero) { $0 + $1.amount.value }
            values.append(L10n.format(
                "상위 3개 결제가 전체 지출의 %@",
                percentage(topThree / report.total)
            ))
        } else if report.count >= 2, report.average > 0, report.maximum >= report.average * 1.5 {
            let ratio = NSDecimalNumber(decimal: report.maximum / report.average).doubleValue
            let ratioText = String(format: "%.1f", locale: AppLanguage.selected.locale, ratio)
            values.append(L10n.format("가장 큰 결제는 평균의 %@배", ratioText))
        }

        return Array(values.prefix(2))
    }

    private func highlightRow(symbol: String, title: String, value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .frame(width: 18)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private func percentage(_ value: Decimal) -> String {
        String(
            format: "%.1f%%",
            locale: AppLanguage.selected.locale,
            NSDecimalNumber(decimal: value * 100).doubleValue
        )
    }

    @ViewBuilder
    private var trialStatus: some View {
        if !purchases.isPremium, consumedThisSession {
            Text(
                remainingFreeUses > 0
                    ? L10n.format("무료 리포트 %d회 남음", remainingFreeUses)
                    : L10n.text("무료 리포트를 모두 사용했습니다. 다음 리포트부터 Premium이 필요합니다.")
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(L10n.text("아직 분석할 영수증이 없습니다."), systemImage: "chart.bar.xaxis")
        } description: {
            Text(L10n.text("영수증을 촬영하거나 가져오면 지출 리포트를 만들어 드립니다."))
        }
        .frame(maxWidth: .infinity, minHeight: 360)
    }

    private var noDataInPeriod: some View {
        ContentUnavailableView(
            L10n.text("이 기간에는 영수증이 없습니다."),
            systemImage: "calendar",
            description: Text(L10n.text("다른 기간을 선택해 보세요."))
        )
        .frame(maxWidth: .infinity, minHeight: 300)
    }

    private func merchantName(_ item: MediaItem) -> String {
        item.receiptMerchant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? L10n.text("상호 미확인")
            : item.receiptMerchant
    }

    private var reportRenderToken: String {
        "\(range.rawValue)|\(items.map { $0.id.uuidString }.joined(separator: ","))"
    }

    private var analyticsRange: SubGalleryAnalytics.ReportRange {
        switch range {
        case .thisMonth: .thisMonth
        case .lastMonth: .lastMonth
        case .threeMonths: .threeMonths
        case .all: .all
        case .custom: .custom
        }
    }

    private func consumeFreeUseAfterRender() {
        guard !consumedThisSession, !purchases.isPremium, !items.isEmpty else { return }
        remainingFreeUses = ReceiptReportUsageStore.consumeIfEligible(
            isPremium: false,
            didRenderReport: true
        )
        consumedThisSession = true
        PremiumAnalytics.trialUsed(.receiptReport, remaining: remainingFreeUses)
    }
}

private struct CompactReportMetric<Content: View>: View {
    let title: String
    let content: Content

    init(
        title: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                content
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
        .background(.background, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }
}

private struct ReceiptMerchantAnalysisView: View {
    let reports: [ReceiptCurrencyReport]

    var body: some View {
        List {
            ForEach(reports) { report in
                if reports.count > 1 {
                    Section {
                        EmptyView()
                    } header: {
                        Text(report.currencyCode)
                    }
                }
                Section(L10n.text("지출이 많은 곳")) {
                    ForEach(report.spendingMerchants) { merchant in
                        merchantRow(merchant, detail: merchant.amount.formatted())
                    }
                }
                Section(L10n.text("자주 결제한 곳")) {
                    ForEach(report.frequentMerchants) { merchant in
                        merchantRow(
                            merchant,
                            detail: "\(L10n.format("%d회", merchant.count)) · \(merchant.amount.formatted())"
                        )
                    }
                }
            }
        }
        .navigationTitle(L10n.text("상호별 분석"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func merchantRow(_ merchant: ReceiptMerchantStat, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(merchant.merchant).lineLimit(1)
            Spacer(minLength: 8)
            Text(detail)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

private struct ReceiptLargestPaymentsView: View {
    let reports: [ReceiptCurrencyReport]
    @State private var detailItem: MediaItem?
    @State private var viewerItem: MediaItem?

    private var items: [MediaItem] {
        reports.flatMap { $0.largestReceipts.map(\.item) }
    }

    var body: some View {
        List {
            ForEach(reports) { report in
                Section(reports.count > 1 ? report.currencyCode : L10n.text("큰 결제")) {
                    ForEach(report.largestReceipts) { ranked in
                        Button { detailItem = ranked.item } label: {
                            HStack(spacing: 12) {
                                MediaThumbnail(item: ranked.item)
                                    .frame(width: 42, height: 52)
                                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(merchantName(ranked.item))
                                        .font(.subheadline.weight(.semibold))
                                    Text(L10n.date(
                                        ranked.item.receiptDisplayDate,
                                        dateStyle: .abbreviated,
                                        timeStyle: .omitted
                                    ))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                                Text(ranked.amount.formatted())
                                    .font(.subheadline.weight(.semibold).monospacedDigit())
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .navigationTitle(L10n.text("큰 결제"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $detailItem) { item in
            ReceiptDetailView(item: item) { viewerItem = item }
        }
        .fullScreenCover(item: $viewerItem) { item in
            MediaViewer(items: items, initialID: item.id, isRecentlyDeleted: false)
        }
    }

    private func merchantName(_ item: MediaItem) -> String {
        item.receiptMerchant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? L10n.text("상호 미확인")
            : item.receiptMerchant
    }
}

private struct SpendingTrendDetailView: View {
    let receipts: [MediaItem]
    @State private var grouping: ReceiptReportGrouping = .day
    @State private var selection: ReceiptReportSelection?
    @State private var detailItem: MediaItem?
    @State private var viewerItem: MediaItem?

    private var analytics: ReceiptReportAnalytics {
        ReceiptReportAnalyticsService.build(items: receipts, grouping: grouping)
    }

    var body: some View {
        List {
            Picker(L10n.text("기간"), selection: $grouping) {
                Text(ReceiptReportGrouping.day.title).tag(ReceiptReportGrouping.day)
                Text(ReceiptReportGrouping.week.title).tag(ReceiptReportGrouping.week)
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)

            ForEach(analytics.currencyReports) { report in
                Section(report.currencyCode) {
                    Chart(report.chartPoints) { point in
                        BarMark(
                            x: .value(L10n.text("날짜"), point.date),
                            y: .value(L10n.text("금액"), point.value.doubleValue)
                        )
                        .foregroundStyle(Color.accentColor.gradient)
                        .cornerRadius(3)
                    }
                    .frame(height: 220)

                    ForEach(report.chartPoints) { point in
                        Button { showReceipts(for: point) } label: {
                            HStack {
                                Text(L10n.date(
                                    point.date,
                                    dateStyle: .abbreviated,
                                    timeStyle: .omitted
                                ))
                                Spacer()
                                Text(ReceiptAmount(
                                    currencyCode: point.currencyCode,
                                    value: point.value
                                ).formatted())
                                .font(.subheadline.weight(.semibold).monospacedDigit())
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .navigationTitle(L10n.text("지출 흐름"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selection) { selection in
            ReceiptReportSelectionView(selection: selection) { item in
                self.selection = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    detailItem = item
                }
            }
        }
        .sheet(item: $detailItem) { item in
            ReceiptDetailView(item: item) { viewerItem = item }
        }
        .fullScreenCover(item: $viewerItem) { item in
            MediaViewer(items: receipts, initialID: item.id, isRecentlyDeleted: false)
        }
    }

    private func showReceipts(for point: ReceiptReportChartPoint) {
        let calendar = Calendar.current
        let interval: DateInterval?
        switch grouping {
        case .day:
            interval = calendar.dateInterval(of: .day, for: point.date)
        case .week:
            interval = calendar.dateInterval(of: .weekOfYear, for: point.date)
        case .month:
            interval = calendar.dateInterval(of: .month, for: point.date)
        }
        guard let interval else { return }
        let matching = receipts.filter { item in
            guard interval.contains(item.receiptDisplayDate),
                  let amount = ReceiptSummaryService.amount(for: item) else { return false }
            return amount.currencyCode == point.currencyCode
        }
        selection = ReceiptReportSelection(
            title: L10n.date(point.date, dateStyle: .long, timeStyle: .omitted),
            items: matching
        )
    }
}

private struct ReceiptReportSelectionView: View {
    @Environment(\.dismiss) private var dismiss
    let selection: ReceiptReportSelection
    let select: (MediaItem) -> Void

    var body: some View {
        NavigationStack {
            List(selection.items) { item in
                Button { select(item) } label: { ReceiptRow(item: item) }
                    .buttonStyle(.plain)
            }
            .navigationTitle(selection.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("완료")) { dismiss() }
                }
            }
        }
    }
}

private extension Decimal {
    var doubleValue: Double { NSDecimalNumber(decimal: self).doubleValue }
}
