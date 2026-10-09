import Foundation
import AppKit

@MainActor
final class Runner: ObservableObject {

    // MARK: Inputs (remembered between launches in UserDefaults — no database, no files)

    @Published var curlText: String { didSet { save("curlText", curlText) } }
    @Published var countText: String { didSet { save("countText", countText) } }
    @Published var intervalText: String { didSet { save("intervalText", intervalText) } }
    @Published var unitIsSeconds: Bool { didSet { save("unitIsSeconds", unitIsSeconds) } }
    @Published var timeoutText: String { didSet { save("timeoutText", timeoutText) } }
    @Published var stopOnFailure: Bool { didSet { save("stopOnFailure", stopOnFailure) } }

    // MARK: Output state

    @Published private(set) var results: [HitResult] = []
    @Published private(set) var isRunning = false
    @Published private(set) var completed = 0
    @Published private(set) var plannedTotal = 0
    @Published var selected: HitResult.ID?
    @Published var status: String = ""
    @Published var statusIsError = false

    private var task: Task<Void, Never>?
    private let defaults = UserDefaults.standard

    init() {
        let d = UserDefaults.standard
        // A public, open, CDN-cached sample endpoint — deliberately gentle defaults
        // so a first run on someone else's server is 5 requests a second apart.
        curlText = d.string(forKey: "curlText") ?? "https://thesimpsonsapi.com/api/characters"
        countText = d.string(forKey: "countText") ?? "5"
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

    var selectedResult: HitResult? {
        if let selected, let hit = results.first(where: { $0.id == selected }) { return hit }
        return results.last
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
        let gap = intervalSeconds
        let timeout = max(1, Double(timeoutText.trimmingCharacters(in: .whitespaces)) ?? 30)
        let request = parsed.urlRequest(defaultTimeout: timeout)

        results.removeAll()
        selected = nil
        completed = 0
        plannedTotal = count
        statusIsError = false
        status = parsed.warnings.isEmpty
            ? "\(parsed.method) \(parsed.url.absoluteString)"
            : parsed.warnings.joined(separator: " ")
        isRunning = true

        let engine = HTTPEngine(request: parsed, timeout: timeout)

        task = Task { [weak self] in
            defer { engine.invalidate() }
            for n in 1...count {
                if Task.isCancelled { break }
                let hit = await engine.send(request, index: n)
                if Task.isCancelled { break }
                guard let self else { return }

                self.results.append(hit)
                self.completed = n
                if self.selected == nil { self.selected = hit.id }

                if self.stopOnFailure && !hit.ok {
                    self.status = "Stopped at hit #\(n) — \(hit.statusLabel)"
                    self.statusIsError = true
                    break
                }
                if n < count && gap > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(gap * 1_000_000_000))
                }
            }
            guard let self else { return }
            self.isRunning = false
            self.task = nil
            if !self.statusIsError && self.completed == self.plannedTotal {
                self.status = "Done — \(self.successCount) ok, \(self.failCount) failed, avg \(Int(self.avgMs)) ms"
            }
        }
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
