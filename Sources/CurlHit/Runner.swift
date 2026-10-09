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

    /// Ramp mode steps through parallelism levels to find where the server bends.
    @Published var isRamp: Bool { didSet { save("isRamp", isRamp) } }
    @Published var rampStepsText: String { didSet { save("rampStepsText", rampStepsText) } }
    @Published var rampPerStepText: String { didSet { save("rampPerStepText", rampPerStepText) } }

    /// Advanced mode: take the request apart and randomise chosen fields per hit.
    @Published var isAdvanced: Bool { didSet { save("isAdvanced", isAdvanced); if isAdvanced { analyse() } } }
    @Published var slots: [FieldSlot] = []
    @Published private(set) var analysisNote: String = ""
    private var template: RequestTemplate?

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
    @Published private(set) var stageWall: [Int: Double] = [:]
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
        isRamp = d.bool(forKey: "isRamp")
        rampStepsText = d.string(forKey: "rampStepsText") ?? "1, 2, 5, 10, 20"
        rampPerStepText = d.string(forKey: "rampPerStepText") ?? "20"
        isAdvanced = d.bool(forKey: "isAdvanced")
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

    /// One row per parallelism level actually exercised.
    struct StageSummary: Identifiable {
        var id: Int { parallel }
        let parallel: Int
        let sent: Int
        let ok: Int
        let rateLimited: Int
        let serverErrors: Int
        let transportFailures: Int
        let avgMs: Double
        let p95Ms: Double
        let reqPerSec: Double
    }

    var stages: [StageSummary] {
        let grouped = Dictionary(grouping: results, by: \.stage)
        return grouped.keys.sorted().map { level in
            let hits = grouped[level] ?? []
            let times = hits.map(\.milliseconds).sorted()
            let wall = stageWall[level] ?? 0
            return StageSummary(
                parallel: level,
                sent: hits.count,
                ok: hits.filter(\.ok).count,
                rateLimited: hits.filter(\.isRateLimited).count,
                serverErrors: hits.filter(\.isServerError).count,
                transportFailures: hits.filter(\.isTransportFailure).count,
                avgMs: times.isEmpty ? 0 : times.reduce(0, +) / Double(times.count),
                p95Ms: Self.percentile(times, 95),
                reqPerSec: wall > 0 ? Double(hits.count) / wall : 0)
        }
    }

    static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let rank = max(0, min(Double(sorted.count - 1), (p / 100) * Double(sorted.count - 1)))
        let low = Int(rank.rounded(.down)), high = Int(rank.rounded(.up))
        if low == high { return sorted[low] }
        return sorted[low] + (sorted[high] - sorted[low]) * (rank - Double(low))
    }

    /// Reads the ramp and says, in one line, what it found. This is the whole
    /// point of ramp mode: the answer, not a table to squint at.
    var rampVerdict: String? {
        let s = stages
        guard s.count > 1 else { return nil }

        if let first = s.first(where: { $0.rateLimited > 0 }) {
            return "Rate limited at \(first.parallel) parallel — \(first.rateLimited)/\(first.sent) got 429."
        }
        if let first = s.first(where: { $0.serverErrors > 0 }) {
            return "Server started failing at \(first.parallel) parallel — \(first.serverErrors)/\(first.sent) returned 5xx."
        }
        if let first = s.first(where: { $0.transportFailures > 0 }) {
            return "Connections started failing at \(first.parallel) parallel — \(first.transportFailures)/\(first.sent) never completed."
        }

        // No hard limit hit. Did latency bend? That is queuing rather than a quota.
        let baseline = s[0].p95Ms
        if baseline > 0, let bend = s.first(where: { $0.p95Ms > baseline * 2 }) {
            return String(format: "No 429s up to %d parallel, but p95 at %d is %.1fx the baseline — queuing, not a quota.",
                          s.last!.parallel, bend.parallel, bend.p95Ms / baseline)
        }
        let peak = s.max(by: { $0.reqPerSec < $1.reqPerSec })
        return String(format: "No limit found up to %d parallel. Peak %.1f req/s, p95 stayed flat.",
                      s.last!.parallel, peak?.reqPerSec ?? 0)
    }

    var selectedResult: HitResult? {
        if let selected, let hit = results.first(where: { $0.id == selected }) { return hit }
        return results.last
    }

    /// Requests fired at once. Capped: this is a replay tool, not a stress rig.
    private var parallelCount: Int {
        max(1, min(50, Int(parallelText.trimmingCharacters(in: .whitespaces)) ?? 1))
    }

    /// The ladder of parallelism levels, e.g. "1, 2, 5, 10, 20". Deduplicated,
    /// sorted, clamped to the same 1...50 ceiling as fixed mode, max 12 rungs.
    var rampSteps: [Int] {
        let parts = rampStepsText.split { ",; \t".contains($0) }
        let levels = parts.compactMap { Int($0) }.map { max(1, min(50, $0)) }
        return Array(Set(levels)).sorted().prefix(12).map { $0 }
    }

    var rampPerStep: Int {
        max(1, min(10_000, Int(rampPerStepText.trimmingCharacters(in: .whitespaces)) ?? 20))
    }

    private var intervalSeconds: Double {
        let raw = Double(intervalText.trimmingCharacters(in: .whitespaces)) ?? 0
        return max(0, unitIsSeconds ? raw : raw / 1000)
    }

    // MARK: Advanced mode

    var enabledSlotCount: Int { slots.filter(\.enabled).count }

    /// Parses the current curl and lists every header, query parameter and body
    /// field it can offer to randomise. Choices already made are preserved across
    /// re-analysis, keyed by field id.
    func analyse() {
        let previous = Dictionary(uniqueKeysWithValues: slots.map { ($0.id, $0) })
        do {
            let parsed = try CurlParser.parse(curlText)
            let built = RequestTemplate.analyse(parsed)
            template = built
            slots = built.slots.map { slot in
                guard let old = previous[slot.id] else { return slot }
                var merged = slot                 // keep the new original value
                merged.enabled = old.enabled
                merged.strategy = old.strategy
                return merged
            }
            if slots.isEmpty {
                analysisNote = "Nothing to randomise — this request has no headers, query parameters or body fields."
            } else {
                let byKind = Dictionary(grouping: slots, by: \.source)
                    .sorted { $0.key.label < $1.key.label }
                    .map { "\($0.value.count) \($0.key.label)" }
                    .joined(separator: ", ")
                analysisNote = "Found \(byKind)."
            }
        } catch {
            template = nil
            slots = []
            analysisNote = error.localizedDescription
        }
    }

    func setAllSlots(enabled: Bool) {
        for i in slots.indices { slots[i].enabled = enabled }
    }

    /// A fresh sample of what this field would send, for the preview column.
    func preview(_ slot: FieldSlot) -> String {
        slot.value(forHit: max(1, completed + 1))
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

        // Both modes reduce to the same thing: a list of (parallel level, how many).
        let plan: [(parallel: Int, count: Int)]
        if isRamp {
            let steps = rampSteps
            guard !steps.isEmpty else {
                status = "Ramp needs at least one parallelism level, e.g. \"1, 2, 5, 10\"."
                statusIsError = true
                return
            }
            let per = rampPerStep
            plan = steps.map { (parallel: $0, count: per) }
        } else {
            let count = max(1, min(100_000, Int(countText.trimmingCharacters(in: .whitespaces)) ?? 1))
            plan = [(parallel: min(parallelCount, count), count: count)]
        }

        let total = plan.reduce(0) { $0 + $1.count }
        let gap = intervalSeconds
        let timeout = max(1, Double(timeoutText.trimmingCharacters(in: .whitespaces)) ?? 30)
        let request = parsed.urlRequest(defaultTimeout: timeout)
        let peakParallel = plan.map(\.parallel).max() ?? 1

        // Advanced mode rebuilds the request per hit so randomised fields differ
        // every time. Plain mode reuses the one request, as before.
        let liveSlots = slots.filter(\.enabled)
        let mutating = isAdvanced && !liveSlots.isEmpty
        if mutating && template == nil { analyse() }
        let liveTemplate = mutating ? template : nil

        results.removeAll()
        stageWall.removeAll()
        selected = nil
        completed = 0
        plannedTotal = total
        wallSeconds = 0
        runStart = Date()
        statusIsError = false
        let shape: String
        if isRamp {
            shape = " · ramp \(plan.map { String($0.parallel) }.joined(separator: "→")) x\(plan[0].count)"
        } else {
            shape = peakParallel > 1 ? " · \(peakParallel) at a time" : ""
        }
        let randomised = mutating ? " · randomising \(liveSlots.count) field\(liveSlots.count == 1 ? "" : "s")" : ""
        status = parsed.warnings.isEmpty
            ? "\(parsed.method) \(parsed.url.absoluteString)\(shape)\(randomised)"
            : parsed.warnings.joined(separator: " ")
        isRunning = true

        let engine = HTTPEngine(request: parsed, timeout: timeout, maxConnections: peakParallel)

        // Each stage sends its requests in waves of `parallel`, then the interval
        // applies before the next wave and before the next stage.
        task = Task { [weak self] in
            defer { engine.invalidate() }
            var hitNumber = 1
            var halted = false

            for (stageIdx, stage) in plan.enumerated() {
                if Task.isCancelled || halted { break }
                let stageStart = Date()
                var sentInStage = 0

                while sentInStage < stage.count && !Task.isCancelled && !halted {
                    let waveSize = min(stage.parallel, stage.count - sentInStage)
                    let indices = Array(hitNumber ..< (hitNumber + waveSize))
                    hitNumber += waveSize
                    sentInStage += waveSize

                    await withTaskGroup(of: HitResult.self) { group in
                        for i in indices {
                            if let liveTemplate {
                                let (built, note) = liveTemplate.request(forHit: i, slots: liveSlots,
                                                                        defaultTimeout: timeout)
                                group.addTask {
                                    var hit = await engine.send(built, index: i, stage: stage.parallel)
                                    hit.mutations = note
                                    return hit
                                }
                            } else {
                                group.addTask { await engine.send(request, index: i, stage: stage.parallel) }
                            }
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
                    if sentInStage < stage.count && gap > 0 {
                        try? await Task.sleep(nanoseconds: UInt64(gap * 1_000_000_000))
                    }
                }

                self?.stageWall[stage.parallel] = Date().timeIntervalSince(stageStart)

                if Task.isCancelled || halted { break }
                if stageIdx < plan.count - 1 && gap > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(gap * 1_000_000_000))
                }
            }

            guard let self else { return }
            self.isRunning = false
            self.task = nil
            if !self.statusIsError && self.completed == self.plannedTotal {
                if self.isRamp, let verdict = self.rampVerdict {
                    self.status = verdict
                } else {
                    var line = "Done — \(self.successCount) ok, \(self.failCount) failed, avg \(Int(self.avgMs)) ms"
                    if peakParallel > 1 {
                        line += String(format: ", %.1f req/s over %.1fs", self.throughput, self.wallSeconds)
                    }
                    self.status = line
                }
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
        stageWall.removeAll()
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

    /// Copies the request that produced the selected hit, as a curl command so it
    /// can be replayed straight from a terminal.
    func copySentRequest() {
        guard let hit = selectedResult else { return }
        var parts = ["curl -X \(hit.sentMethod) '\(hit.sentURL)'"]
        for (name, value) in hit.sentHeaders {
            parts.append("  -H '\(name): \(value.replacingOccurrences(of: "'", with: "'\\''"))'")
        }
        if let body = hit.sentBody, !body.isEmpty {
            parts.append("  --data-raw '\(body.replacingOccurrences(of: "'", with: "'\\''"))'")
        }
        copy(parts.joined(separator: " \\\n"), note: "Request of hit #\(hit.index) copied as curl.")
    }

    /// CSV of the run — plain text to the clipboard, nothing written to disk.
    func copyRunAsCSV() {
        guard !results.isEmpty else { return }
        var lines = ["hit,parallel,status,ms,bytes,started_at,error,randomised"]
        let fmt = ISO8601DateFormatter()
        for hit in results {
            let err = (hit.errorText ?? "").replacingOccurrences(of: "\"", with: "'")
            let mut = (hit.mutations ?? "").replacingOccurrences(of: "\"", with: "'")
            lines.append("\(hit.index),\(hit.stage),\(hit.statusLabel),\(String(format: "%.1f", hit.milliseconds)),\(hit.byteCount),\(fmt.string(from: hit.startedAt)),\"\(err)\",\"\(mut)\"")
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
