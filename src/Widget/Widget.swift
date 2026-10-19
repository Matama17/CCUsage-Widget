import WidgetKit
import SwiftUI

// Claude 브랜드 오렌지. 위젯은 라이트/다크를 모두 타므로 나머지 색은 시맨틱 색으로 둔다.
let claudeOrange = Color(red: 0.851, green: 0.467, blue: 0.341)
let codexGreen  = Color(red: 0.063, green: 0.639, blue: 0.498)

/// 한도 갱신이 실패했을 때만 헤더 우측에 표시한다. 평소에는 아무것도 띄우지 않는다.
/// 이유를 알면 그대로 보여준다 — "갱신 실패" 만으로는 뭘 해야 할지 알 수 없다.
func staleNote(_ u: Usage) -> String? {
    guard let p = (u.providers ?? []).first(where: { $0.stale }) else { return nil }
    return p.reason ?? "갱신 실패"
}

func brandColor(_ providerID: String) -> Color {
    providerID == "codex" ? codexGreen : claudeOrange
}

// MARK: - Timeline

struct UsageEntry: TimelineEntry {
    let date: Date
    let usage: Usage?
    let stale: Bool
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> UsageEntry {
        UsageEntry(date: .now, usage: .sample, stale: false)
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        // 갤러리 미리보기에서는 항상 샘플을 보여준다.
        let u = context.isPreview ? Usage.sample : SnapshotStore.read()
        completion(UsageEntry(date: .now, usage: u ?? .sample, stale: false))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        let u = SnapshotStore.read()
        // 앱이 죽어 스냅샷이 10분 이상 묵으면 표시해 준다.
        let stale = (u.map { Date().timeIntervalSince1970 - $0.generated > 600 }) ?? true
        let entry = UsageEntry(date: .now, usage: u, stale: stale)
        completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(600))))
    }
}

// MARK: - 공통 조각

/// 위젯 상단 라벨 줄. Apple 위젯 관례대로 강조색 + 소문자 캡션.
struct WidgetHeader: View {
    var title: String = "Claude Code"
    var trailing: String?

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "sparkle")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(claudeOrange)
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(claudeOrange)
                .lineLimit(1)
            if let t = trailing {
                Spacer(minLength: 2)
                Text(t)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

struct ProgressBar: View {
    let value: Double
    var tint: Color = claudeOrange
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(tint)
                    .frame(width: max(height, g.size.width * min(max(value, 0), 1)))
            }
        }
        .frame(height: height)
    }
}

/// 사용률이 높으면 브랜드색 대신 경고색으로 넘어간다.
func limitTint(_ used: Int, brand: Color) -> Color {
    if used >= 90 { return Color(red: 0.90, green: 0.28, blue: 0.24) }
    if used >= 75 { return Color(red: 0.95, green: 0.62, blue: 0.16) }
    return brand
}

/// 리셋 시각을 어떻게 붙일지.
///  - inline: 라벨 옆에 24시간 표기 (세션처럼 곧 리셋되는 한도)
///  - below : 막대 아래 한 줄 (주간처럼 며칠 뒤라 날짜로 보는 한도)
enum ResetStyle { case none, inline, below }

/// 한도 한 줄: 라벨 · (리셋) · 남은 % · 사용량 막대
struct LimitRow: View {
    let limit: Limit
    let brand: Color
    var reset: ResetStyle = .below

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(limit.label)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if reset == .inline, let r = limit.reset {
                    Text(Fmt.clock24(r))
                        .font(.system(size: 9, design: .rounded))
                        .foregroundStyle(.quaternary)
                        .lineLimit(1)
                }
                Spacer(minLength: 2)
                Text("\(limit.remaining)%")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
            }
            ProgressBar(value: Double(limit.used) / 100,
                        tint: limitTint(limit.used, brand: brand), height: 3)
            if reset == .below, let r = limit.reset {
                Text(Fmt.resetLabel(r))
                    .font(.system(size: 8, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// 세션 외 한도(주간 등)의 리셋을 아래 줄에 보여줄지. 세션은 항상 라벨 옆에 붙는다.
enum ResetPolicy { case sessionOnly, all }

/// 제품 하나의 한도 묶음. 헤더(제품명) + 한도 줄들.
struct ProviderColumn: View {
    let provider: LimitProvider
    var maxRows = 3
    var resets: ResetPolicy = .all

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Circle().fill(brandColor(provider.id)).frame(width: 6, height: 6)
                Text(provider.name)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if provider.stale {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 7))
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            ForEach(provider.limits.prefix(maxRows)) { l in
                LimitRow(limit: l, brand: brandColor(provider.id),
                         reset: l.isSession ? .inline : (resets == .all ? .below : .none))
            }
            Spacer(minLength: 0)
        }
    }
}

/// 작은 위젯용: 제품명 + 세션 한도만 크게.
struct ProviderCompact: View {
    let provider: LimitProvider

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Circle().fill(brandColor(provider.id)).frame(width: 5, height: 5)
                Text(provider.name)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Spacer(minLength: 2)
                Text("\(provider.session?.remaining ?? 0)%")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
            }
            ProgressBar(value: Double(provider.session?.used ?? 0) / 100,
                        tint: limitTint(provider.session?.used ?? 0, brand: brandColor(provider.id)),
                        height: 3)
            if let r = provider.session?.reset {
                Text(Fmt.clock24(r))
                    .font(.system(size: 9, design: .rounded))
                    .foregroundStyle(.quaternary)
            }
        }
    }
}

struct StatColumn: View {
    let label: String
    let cost: Double
    let tok: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tertiary)
            Text(Fmt.cost(cost))
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
            Text(Fmt.tok(tok))
                .font(.system(size: 9, design: .rounded))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct DayChart: View {
    let days: [Day]
    var barWidth: CGFloat? = nil

    var body: some View {
        let maxV = max(days.map(\.cost).max() ?? 1, 0.01)
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(Array(days.enumerated()), id: \.element.id) { i, d in
                let isToday = i == days.count - 1
                VStack(spacing: 3) {
                    GeometryReader { g in
                        VStack {
                            Spacer(minLength: 0)
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(isToday ? AnyShapeStyle(claudeOrange) : AnyShapeStyle(.quaternary))
                                .frame(height: max(2, g.size.height * (d.cost / maxV)))
                        }
                    }
                    Text(d.date)
                        .font(.system(size: 7, design: .rounded))
                        .foregroundStyle(isToday ? AnyShapeStyle(claudeOrange) : AnyShapeStyle(.tertiary))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .frame(width: barWidth)
            }
        }
    }
}

/// 스냅샷이 아직 없을 때(앱 미실행) 보여줄 안내.
struct EmptyState: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            WidgetHeader()
            Spacer(minLength: 0)
            Text("데이터 없음")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("CCUsage 앱을 실행하세요")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Small  (콘텐츠 128×128)

struct SmallView: View {
    let entry: UsageEntry

    var body: some View {
        if let u = entry.usage, let ps = u.providers, !ps.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                WidgetHeader(title: "사용 한도")
                ForEach(ps.prefix(2)) { ProviderCompact(provider: $0) }
                Spacer(minLength: 0)
            }
        } else if let u = entry.usage {
            NoLimits(usage: u)
        } else {
            EmptyState()
        }
    }
}

/// 한도를 하나도 못 읽었을 때. 시간 기반 표시임을 문구로 분명히 한다.
struct NoLimits: View {
    let usage: Usage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            WidgetHeader()
            Spacer(minLength: 4)
            Text("5시간 블록 경과")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tertiary)
            if let b = usage.block, b.active {
                let elapsed = (Date().timeIntervalSince1970 - b.start) / max(b.end - b.start, 1)
                Text("\(Int(min(max(elapsed, 0), 1) * 100))%")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                ProgressBar(value: elapsed, height: 4)
                Text(Fmt.remain(b.end - Date().timeIntervalSince1970) + " 후 리셋")
                    .font(.system(size: 9, design: .rounded))
                    .foregroundStyle(.tertiary)
            } else {
                Text("활동 없음")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Medium  (콘텐츠 308×152)

struct MediumView: View {
    let entry: UsageEntry

    var body: some View {
        if let u = entry.usage, let ps = u.providers, !ps.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                WidgetHeader(title: "사용 한도", trailing: staleNote(u))
                HStack(alignment: .top, spacing: 16) {
                    ForEach(ps.prefix(2)) { p in
                        ProviderColumn(provider: p, maxRows: 3, resets: .sessionOnly)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Spacer(minLength: 0)
            }
        } else if let u = entry.usage {
            NoLimits(usage: u)
        } else {
            EmptyState()
        }
    }
}

// MARK: - Large  (콘텐츠 308×344)

struct LargeView: View {
    let entry: UsageEntry

    var body: some View {
        if let u = entry.usage {
            VStack(alignment: .leading, spacing: 10) {
                WidgetHeader(title: "사용 한도", trailing: staleNote(u))

                if let ps = u.providers, !ps.isEmpty {
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(ps.prefix(2)) { p in
                            ProviderColumn(provider: p, maxRows: 3, resets: .all)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    Divider()
                }

                HStack(spacing: 8) {
                    StatColumn(label: "오늘", cost: u.today.cost, tok: u.today.tok)
                    StatColumn(label: "7일", cost: u.week.cost, tok: u.week.tok)
                    StatColumn(label: "30일", cost: u.month.cost, tok: u.month.tok)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Claude Code 일별")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                    DayChart(days: u.days).frame(height: 52)
                }

                if !u.today.models.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(u.today.models.prefix(2)) { m in
                            HStack(spacing: 6) {
                                Circle().fill(claudeOrange.opacity(0.8)).frame(width: 5, height: 5)
                                Text(m.short)
                                    .font(.system(size: 11, design: .rounded))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                Text(Fmt.tok(m.tok))
                                    .font(.system(size: 10, design: .rounded))
                                    .foregroundStyle(.tertiary)
                                Text(Fmt.cost(m.cost))
                                    .font(.system(size: 11, weight: .medium, design: .rounded))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 52, alignment: .trailing)
                            }
                        }
                    }
                }

                Spacer(minLength: 0)
            }
        } else {
            EmptyState()
        }
    }
}

// MARK: - Entry point

struct CCUsageEntryView: View {
    @Environment(\.widgetFamily) var family
    let entry: UsageEntry

    var body: some View {
        Group {
            switch family {
            case .systemSmall:  SmallView(entry: entry)
            case .systemLarge:  LargeView(entry: entry)
            default:            MediumView(entry: entry)
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct CCUsageWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "CCUsageWidget", provider: Provider()) { entry in
            CCUsageEntryView(entry: entry)
        }
        .configurationDisplayName("Claude Code 사용량")
        .description("현재 5시간 블록과 오늘·주간·월간 토큰 사용량을 봅니다.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@main
struct CCUsageWidgetBundle: WidgetBundle {
    var body: some Widget {
        CCUsageWidget()
    }
}
