import Foundation
import AppKit

@MainActor
final class Runner: ObservableObject {

    // MARK: Inputs (remembered between launches in UserDefaults — no database, no files)

    @Published var curlText: String { didSet { save("curlText", curlText) } }
    @Published var countText: String { didSet { save("countText", countText) } }
    @Published var parallelText: String { didSet { save("parallelText", parallelText) } }
    @Published var intervalText: String { didSet { save("intervalText", intervalText) } }
    @Published var unitIsSeconds: Bool { didSet { save("unitIsSeconds", unitIsSeconds) } }
    @Published var timeoutText: String { didSet { save("timeoutText", timeoutText) } }
    @Published var stopOnFailure: Bool { didSet { save("stopOnFailure", stopOnFailure) } }

    // MARK: Output state

    @Published private(set) var results: [HitResult] = []
    @Published private(set) var isRunning = false
    @Published private(set) var completed = 0
    @Published private(set) var plannedTotal = 0
    @Published private(set) var wallSeconds: Double = 0
    @Published var selected: HitResult.ID?
    @Published var status: String = ""
    @Published var statusIsError = false

    private var task: Task<Void, Never>?
    private var runStart: Date?
    private let defaults = UserDefaults.standard

    init() {
        let d = UserDefaults.standard
        // A public, open, CDN-cached sample endpoint — deliberately gentle defaults
        // so a first run on someone else's server is 5 requests a second apart.
        curlText = d.string(forKey: "curlText") ?? "https://thesimpsonsapi.com/api/characters"
        countText = d.string(forKey: "countText") ?? "5"
        parallelText = d.string(forKey: "parallelText") ?? "1"
        intervalText = d.string(forKey: "intervalText") ?? "1000"
        timeoutText = d.string(forKey: "timeoutText") ?? "30"
        unitIsSeconds = d.bool(forKey: "unitIsSeconds")
        stopOnFailure = d.bool(forKey: "stopOnFailure")
    }

    private func save(_ key: String, _ value: Any) { defaults.set(value, forKey: key) }

    // MARK: Derived stats

    var successCount: Int { results.reduce(0) { $0 + ($1.ok ? 1 : 0) } }
    var failCount: Int { results.count - successCount }
    var avgMs: Double {
        guard !results.isEmpty else { return 0 }
        return results.reduce(0.0) { $0 + $1.milliseconds } / Double(results.count)
    }
    var minMs: Double { results.map(\.milliseconds).min() ?? 0 }
    var maxMs: Double { results.map(\.milliseconds).max() ?? 0 }
    var lastMs: Double { results.last?.milliseconds ?? 0 }

    /// Tail latency — the number that exposes a throttle or a queue far better
    /// than the average does.
    func percentileMs(_ p: Double) -> Double {
        guard !results.isEmpty else { return 0 }
        let sorted = results.map(\.milliseconds).sorted()
        let rank = max(0, min(Double(sorted.count - 1), (p / 100) * Double(sorted.count - 1)))
        let low = Int(rank.rounded(.down)), high = Int(rank.rounded(.up))
        if low == high { return sorted[low] }
        return sorted[low] + (sorted[high] - sorted[low]) * (rank - Double(low))
    }

    var p95Ms: Double { percentileMs(95) }

    /// Requests actually completed per second of wall-clock time — the number
    /// that moves when you raise the parallel setting.
    var throughput: Double {
        wallSeconds > 0 ? Double(results.count) / wallSeconds : 0
    }

    /// How many of each status code came back — the headline number when you are
    /// probing a rate limit (e.g. "200 x45   429 x15").
    var statusBreakdown: [(label: String, count: Int, code: Int)] {
        var counts: [Int: Int] = [:]
        for hit in results { counts[hit.statusCode, default: 0] += 1 }
        return counts.sorted { $0.key < $1.key }
            .map { (label: $0.key == 0 ? "ERR" : String($0.key), count: $0.value, code: $0.key) }
    }

    /// Rate-limit headers off the most recent response, if the server sends any.
    /// Covers both the `X-RateLimit-*` and the RFC-style `RateLimit-*` spellings.
    var rateLimitInfo: String? {
        let wanted: Set<String> = ["retry-after",
                                   "x-ratelimit-limit", "x-ratelimit-remaining", "x-ratelimit-reset",
                                   "ratelimit-limit", "ratelimit-remaining", "ratelimit-reset",
                                   "x-rate-limit-limit", "x-rate-limit-remaining"]
        for hit in results.reversed() {
            let found = hit.responseHeaders.filter { wanted.contains($0.0.lowercased()) }
            if !found.isEmpty {
                return found.map { "\($0.0): \($0.1)" }.joined(separator: "   ")
            }
        }
        return nil
    }

    var selectedResult: HitResult? {
        if let selected, let hit = results.first(where: { $0.id == selected }) { return hit }
        return results.last
    }

    /// Requests fired at once. Capped: this is a replay tool, not a stress rig.
    private var parallelCount: Int {
        max(1, min(50, Int(parallelText.trimmingCharacters(in: .whitespaces)) ?? 1))
    }

    private var intervalSeconds: Double {
        let raw = Double(intervalText.trimmingCharacters(in: .whitespaces)) ?? 0
        return max(0, unitIsSeconds ? raw : raw / 1000)
    }

    // MARK: Actions

    func start() {
        guard !isRunning else { return }

        let parsed: ParsedRequest
        do {
            parsed = try CurlParser.parse(curlText)
        } catch {
            status = error.localizedDescription
            statusIsError = true
            return
        }

        let count = max(1, min(100_000, Int(countText.trimmingCharacters(in: .whitespaces)) ?? 1))
        let parallel = min(parallelCount, count)
        let gap = intervalSeconds
        let timeout = max(1, Double(timeoutText.trimmingCharacters(in: .whitespaces)) ?? 30)
        let request = parsed.urlRequest(defaultTimeout: timeout)

        results.removeAll()
        selected = nil
        completed = 0
        plannedTotal = count
        wallSeconds = 0
        runStart = Date()
        statusIsError = false
        let shape = parallel > 1 ? " · \(parallel) at a time" : ""
        status = parsed.warnings.isEmpty
            ? "\(parsed.method) \(parsed.url.absoluteString)\(shape)"
            : parsed.warnings.joined(separator: " ")
        isRunning = true

        let engine = HTTPEngine(request: parsed, timeout: timeout, maxConnections: parallel)

        // Sent in waves: `parallel` requests go out together, the wave is awaited,
        // then the interval applies before the next one. With parallel == 1 this is
        // exactly the old one-at-a-time behaviour.
        task = Task { [weak self] in
            defer { engine.invalidate() }
            var next = 1
            var halted = false

            while next <= count && !Task.isCancelled && !halted {
                let waveSize = min(parallel, count - next + 1)
                let indices = Array(next ..< (next + waveSize))
                next += waveSize

                await withTaskGroup(of: HitResult.self) { group in
                    for i in indices {
                        group.addTask { await engine.send(request, index: i) }
                    }
                    for await hit in group {
                        guard let self else { continue }
                        self.record(hit)
                        if self.stopOnFailure && !hit.ok && !halted {
                            halted = true
                            self.status = "Stopped at hit #\(hit.index) — \(hit.statusLabel)"
                            self.statusIsError = true
                        }
                    }
                }

                if Task.isCancelled || halted { break }
                if next <= count && gap > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(gap * 1_000_000_000))
                }
            }

            guard let self else { return }
            self.isRunning = false
            self.task = nil
            if !self.statusIsError && self.completed == self.plannedTotal {
                var line = "Done — \(self.successCount) ok, \(self.failCount) failed, avg \(Int(self.avgMs)) ms"
                if parallel > 1 {
                    line += String(format: ", %.1f req/s over %.1fs", self.throughput, self.wallSeconds)
                }
                self.status = line
            }
        }
    }

    /// Waves complete out of order, so results are kept sorted by hit number
    /// rather than by arrival.
    private func record(_ hit: HitResult) {
        let pos = results.firstIndex { $0.index > hit.index } ?? results.endIndex
        results.insert(hit, at: pos)
        completed += 1
        if let runStart { wallSeconds = Date().timeIntervalSince(runStart) }
        if selected == nil { selected = hit.id }
    }

    func stop() {
        task?.cancel()
        task = nil
        isRunning = false
        status = "Stopped at \(completed)/\(plannedTotal)."
        statusIsError = false
    }

    func clear() {
        results.removeAll()
        completed = 0
        plannedTotal = 0
        wallSeconds = 0
        runStart = nil
        selected = nil
        status = ""
        statusIsError = false
    }

    func copyResponse() {
        guard let hit = selectedResult else { return }
        var text = ""
        if let err = hit.errorText { text += "Error: \(err)\n\n" }
        if !hit.responseHeaders.isEmpty {
            text += hit.responseHeaders.map { "\($0.0): \($0.1)" }.joined(separator: "\n") + "\n\n"
        }
        text += hit.body
        copy(text, note: "Response of hit #\(hit.index) copied.")
    }

    /// CSV of the run — plain text to the clipboard, nothing written to disk.
    func copyRunAsCSV() {
        guard !results.isEmpty else { return }
        var lines = ["hit,status,ms,bytes,started_at,error"]
        let fmt = ISO8601DateFormatter()
        for hit in results {
            let err = (hit.errorText ?? "").replacingOccurrences(of: "\"", with: "'")
            lines.append("\(hit.index),\(hit.statusLabel),\(String(format: "%.1f", hit.milliseconds)),\(hit.byteCount),\(fmt.string(from: hit.startedAt)),\"\(err)\"")
        }
        copy(lines.joined(separator: "\n"), note: "\(results.count) rows copied as CSV.")
    }

    private func copy(_ text: String, note: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        status = note
        statusIsError = false
    }
}
