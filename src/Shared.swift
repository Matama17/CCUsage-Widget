import Foundation

// MARK: - 스냅샷 모델
//
// collect.py 가 내보내는 JSON 과 1:1 로 대응한다.
// 앱(비샌드박스)이 이 구조를 App Group 컨테이너에 쓰고, 위젯(샌드박스)이 읽는다.

struct ModelStat: Codable, Identifiable, Hashable {
    let model: String
    let cost: Double
    let tok: Int
    var id: String { model }

    /// "claude-haiku-4-5-20251001" -> "haiku-4-5"
    var short: String {
        var m = model.replacingOccurrences(of: "claude-", with: "")
        if let r = m.range(of: "-20", options: .backwards) { m = String(m[m.startIndex..<r.lowerBound]) }
        return m
    }
}

struct Bucket: Codable, Hashable {
    let cost: Double
    let tok: Int
    let n: Int
    let models: [ModelStat]

    static let empty = Bucket(cost: 0, tok: 0, n: 0, models: [])
}

struct Block: Codable, Hashable {
    let active: Bool
    let start: Double
    let end: Double
    let cost: Double
    let tok: Int
    let n: Int
}

struct Day: Codable, Identifiable, Hashable {
    let date: String
    let cost: Double
    let tok: Int
    var id: String { date }
}

/// 한도 한 건. Claude Code 와 Codex 가 같은 모양으로 들어온다.
struct Limit: Codable, Identifiable, Hashable {
    let scope: String
    let label: String
    let used: Int
    let reset: Double?

    var id: String { scope + label }
    var remaining: Int { max(0, 100 - used) }
    var isSession: Bool { scope == "session" }
}

/// 한도를 제공하는 제품(Claude Code / Codex).
struct LimitProvider: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let plan: String?
    let stale: Bool
    let fetched: Double
    /// 갱신에 실패한 이유. "로그인 필요" 처럼 사용자가 손쓸 수 있는 말이 들어온다.
    let reason: String?
    let limits: [Limit]

    var session: Limit? { limits.first { $0.isSession } }
    var others: [Limit] { limits.filter { !$0.isSession } }
}

struct Usage: Codable, Hashable {
    let generated: Double
    let block: Block?
    let today: Bucket
    let week: Bucket
    let month: Bucket
    let days: [Day]
    let last_activity: Double
    let providers: [LimitProvider]?

    /// 위젯 갤러리 미리보기 / 플레이스홀더용 더미 데이터.
    static let sample = Usage(
        generated: Date().timeIntervalSince1970,
        block: Block(active: true,
                     start: Date().timeIntervalSince1970 - 5000,
                     end: Date().timeIntervalSince1970 + 13000,
                     cost: 4.62, tok: 2_840_000, n: 37),
        today: Bucket(cost: 12.40, tok: 8_100_000, n: 96,
                      models: [ModelStat(model: "claude-opus-5", cost: 11.8, tok: 7_400_000),
                               ModelStat(model: "claude-haiku-4-5", cost: 0.6, tok: 700_000)]),
        week: Bucket(cost: 214.30, tok: 141_000_000, n: 1120, models: []),
        month: Bucket(cost: 631.90, tok: 402_000_000, n: 3400, models: []),
        days: ["월", "화", "수", "목", "금", "토", "일"].enumerated().map {
            Day(date: $0.element, cost: [3.1, 8.4, 21.0, 14.2, 6.6, 2.0, 12.4][$0.offset], tok: 0)
        },
        last_activity: Date().timeIntervalSince1970 - 300,
        providers: [
            LimitProvider(id: "claude", name: "Claude Code", plan: nil, stale: false,
                     fetched: Date().timeIntervalSince1970, reason: nil, limits: [
                Limit(scope: "session", label: "5시간 세션", used: 31,
                      reset: Date().timeIntervalSince1970 + 7600),
                Limit(scope: "week", label: "주간 전체", used: 34,
                      reset: Date().timeIntervalSince1970 + 400000),
                Limit(scope: "week_model", label: "주간 Opus", used: 61,
                      reset: Date().timeIntervalSince1970 + 400000),
            ]),
            LimitProvider(id: "codex", name: "Codex", plan: "plus", stale: false,
                     fetched: Date().timeIntervalSince1970, reason: nil, limits: [
                Limit(scope: "session", label: "5시간 세션", used: 29,
                      reset: Date().timeIntervalSince1970 + 13600),
                Limit(scope: "week", label: "주간 전체", used: 22,
                      reset: Date().timeIntervalSince1970 + 55000),
            ]),
        ]
    )
}

// MARK: - App Group 저장소

enum SnapshotStore {
    /// App Group ID. 실서명 시에는 Team ID 접두사가 붙으므로 빌드 시점에 Info.plist 로 주입한다.
    static let groupID = Bundle.main.object(forInfoDictionaryKey: "CCUsageAppGroup") as? String
        ?? "group.local.ccusage"
    static let fileName = "snapshot.json"

    /// 샌드박스된 위젯은 이 API 로만 컨테이너를 얻을 수 있다.
    /// 비샌드박스 앱에서는 nil 이 날 수 있어 리터럴 경로로 폴백한다.
    static var containerURL: URL {
        if let u = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) {
            return u
        }
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Group Containers")
            .appendingPathComponent(groupID)
    }

    static var fileURL: URL { containerURL.appendingPathComponent(fileName) }

    static func read() -> Usage? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(Usage.self, from: data)
    }

    static func write(_ data: Data) throws {
        try FileManager.default.createDirectory(at: containerURL, withIntermediateDirectories: true)
        let tmp = fileURL.appendingPathExtension("tmp")
        try data.write(to: tmp)
        _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tmp)
    }
}

// MARK: - 표기

enum Fmt {
    static func cost(_ v: Double) -> String {
        if v >= 1000 { return String(format: "$%.0f", v) }
        if v >= 100 { return String(format: "$%.1f", v) }
        return String(format: "$%.2f", v)
    }

    static func tok(_ v: Int) -> String {
        let d = Double(v)
        if d >= 1_000_000_000 { return String(format: "%.1fB", d / 1e9) }
        if d >= 1_000_000 { return String(format: "%.1fM", d / 1e6) }
        if d >= 1_000 { return String(format: "%.0fK", d / 1e3) }
        return "\(v)"
    }

    static func remain(_ secs: Double) -> String {
        if secs <= 0 { return "종료" }
        let m = Int(secs) / 60
        return m >= 60 ? "\(m / 60)시간 \(m % 60)분" : "\(m)분"
    }

    /// 리셋 시각을 24시간 표기로. 오전 11시 -> "11:00", 오후 10시 -> "22:00".
    static func clock24(_ ts: Double) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f.string(from: Date(timeIntervalSince1970: ts))
    }

    /// 리셋 시각을 "3:09am" 형태로.
    static func clock(_ ts: Double) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "h:mma"
        f.amSymbol = "am"; f.pmSymbol = "pm"
        return f.string(from: Date(timeIntervalSince1970: ts))
    }

    /// 주간처럼 먼 리셋은 "9/13" 처럼 날짜로.
    static func resetLabel(_ ts: Double) -> String {
        let d = Date(timeIntervalSince1970: ts)
        if d.timeIntervalSinceNow < 24 * 3600 { return clock(ts) + " 리셋" }
        let f = DateFormatter()
        f.dateFormat = "M/d"
        return f.string(from: d) + " 리셋"
    }

    static func time(_ ts: Double) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: Date(timeIntervalSince1970: ts))
    }
}
