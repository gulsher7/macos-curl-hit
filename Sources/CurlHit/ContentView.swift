import SwiftUI

struct ContentView: View {
    @StateObject private var runner = Runner()
    @State private var showHeaders = false
    @State private var showStages = true
    @State private var showRequest = false

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Divider()
            controlPanel
            Divider()
            resultsPane
            Divider()
            statusBar
        }
        .frame(minWidth: 940, minHeight: 680)
        .onAppear { if runner.isAdvanced { runner.analyse() } }
    }

    // MARK: Title

    private var titleBar: some View {
        HStack(spacing: 9) {
            Image(systemName: "bolt.horizontal.circle.fill")
                .font(.system(size: 19))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 0) {
                Text("Curl Hit").font(.system(size: 13, weight: .bold))
                Text("Paste a curl, set a count and an interval, fire.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()

            Picker("", selection: $runner.isAdvanced) {
                Text("Simple").tag(false)
                Text("Advanced").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 148)
            .controlSize(.small)
            .disabled(runner.isRunning)
            .help("Advanced mode takes the request apart so individual fields can be randomised per hit")

            if runner.isRunning {
                ProgressView().controlSize(.small)
                Text("\(runner.completed)/\(runner.plannedTotal)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    // MARK: Controls

    private var controlPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Label("Request", systemImage: "terminal")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Button {
                    if let s = NSPasteboard.general.string(forType: .string), !s.isEmpty {
                        runner.curlText = s
                    }
                } label: {
                    Label("Paste from clipboard", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
                .disabled(runner.isRunning)
            }

            TextEditor(text: $runner.curlText)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(7)
                .frame(height: 96)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.13)))
                .disabled(runner.isRunning)
                .onChange(of: runner.curlText) { _ in
                    if runner.isAdvanced { runner.analyse() }
                }

            if runner.isAdvanced {
                fieldsPanel
            }

            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    fieldLabel("Mode")
                    Picker("", selection: $runner.isRamp) {
                        Text("Fixed").tag(false)
                        Text("Ramp").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 112)
                    .disabled(runner.isRunning)
                }

                if runner.isRamp {
                    VStack(alignment: .leading, spacing: 3) {
                        fieldLabel("Parallel levels")
                        TextField("1, 2, 5, 10, 20", text: $runner.rampStepsText)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(width: 136)
                            .disabled(runner.isRunning)
                    }
                    numberField("Per level", text: $runner.rampPerStepText)
                } else {
                    numberField("Count", text: $runner.countText)
                    numberField("Parallel", text: $runner.parallelText)
                }

                VStack(alignment: .leading, spacing: 3) {
                    fieldLabel("Interval")
                    HStack(spacing: 5) {
                        TextField("", text: $runner.intervalText)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(width: 72)
                            .disabled(runner.isRunning)
                        Picker("", selection: $runner.unitIsSeconds) {
                            Text("ms").tag(false)
                            Text("sec").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 86)
                        .disabled(runner.isRunning)
                    }
                }

                numberField("Timeout (s)", text: $runner.timeoutText)

                Toggle("Stop on failure", isOn: $runner.stopOnFailure)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                    .disabled(runner.isRunning)

                Spacer()

                if runner.isRunning {
                    Button(role: .destructive) { runner.stop() } label: {
                        Label("Stop", systemImage: "stop.fill").frame(width: 62)
                    }
                    .keyboardShortcut(".", modifiers: .command)
                } else {
                    Button { runner.start() } label: {
                        Label("Start", systemImage: "play.fill").frame(width: 62)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                }

                Button("Clear") { runner.clear() }
                    .disabled(runner.isRunning || runner.results.isEmpty)
            }

            HStack(spacing: 7) {
                stat("Sent", "\(runner.results.count)")
                stat("OK", "\(runner.successCount)", tint: .green)
                stat("Failed", "\(runner.failCount)", tint: runner.failCount > 0 ? .red : .secondary)
                stat("Avg", ms(runner.avgMs))
                stat("p95", ms(runner.p95Ms))
                stat("Max", ms(runner.maxMs))
                stat("Req/s", runner.throughput == 0 ? "—" : String(format: "%.1f", runner.throughput))
                Spacer()
                Button {
                    runner.copyRunAsCSV()
                } label: {
                    Label("Copy CSV", systemImage: "tablecells")
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
                .disabled(runner.results.isEmpty)
            }

            if runner.plannedTotal > 0 {
                ProgressView(value: Double(runner.completed), total: Double(runner.plannedTotal))
                    .progressViewStyle(.linear)
            }

            if runner.isRamp, !runner.isRunning, let verdict = runner.rampVerdict {
                HStack(spacing: 7) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.system(size: 12))
                        .foregroundStyle(.tint)
                    Text(verdict)
                        .font(.system(size: 12, weight: .medium))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.accentColor.opacity(0.30)))
            }

            if !runner.statusBreakdown.isEmpty {
                HStack(spacing: 6) {
                    ForEach(runner.statusBreakdown, id: \.code) { entry in
                        HStack(spacing: 3) {
                            Text(entry.label)
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                            Text("x\(entry.count)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(codeColor(entry.code).opacity(0.16), in: Capsule())
                        .overlay(Capsule().stroke(codeColor(entry.code).opacity(0.45)))
                    }
                    Spacer()
                }
            }

            if let limits = runner.rateLimitInfo {
                HStack(spacing: 5) {
                    Image(systemName: "gauge.with.dots.needle.33percent")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                    Text(limits)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                }
            }
        }
        .padding(14)
    }

    // MARK: Advanced — per-field randomisation

    private var fieldsPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label("Randomise per request", systemImage: "dice")
                    .font(.system(size: 11, weight: .semibold))
                if runner.enabledSlotCount > 0 {
                    Text("\(runner.enabledSlotCount) on")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Color.accentColor, in: Capsule())
                }
                Spacer()
                Button("Re-read") { runner.analyse() }
                    .buttonStyle(.link).font(.system(size: 11))
                Button("All") { runner.setAllSlots(enabled: true) }
                    .buttonStyle(.link).font(.system(size: 11))
                Button("None") { runner.setAllSlots(enabled: false) }
                    .buttonStyle(.link).font(.system(size: 11))
            }
            .disabled(runner.isRunning)

            if runner.slots.isEmpty {
                Text(runner.analysisNote.isEmpty
                     ? "Paste a request above to see the fields it can randomise."
                     : runner.analysisNote)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                Text(runner.analysisNote)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)

                ScrollView {
                    VStack(spacing: 0) {
                        ForEach($runner.slots) { $slot in
                            fieldRow($slot)
                            Divider().opacity(0.35)
                        }
                    }
                }
                .frame(height: min(CGFloat(runner.slots.count) * 29 + 4, 190))
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.12)))
            }
        }
    }

    private func fieldRow(_ slot: Binding<FieldSlot>) -> some View {
        HStack(spacing: 7) {
            Toggle("", isOn: slot.enabled)
                .labelsHidden()
                .controlSize(.small)
                .disabled(runner.isRunning)

            Text(slot.wrappedValue.source.label)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(sourceColor(slot.wrappedValue.source), in: RoundedRectangle(cornerRadius: 3))
                .frame(width: 48, alignment: .leading)

            Text(slot.wrappedValue.path)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1).truncationMode(.middle)
                .frame(width: 148, alignment: .leading)
                .help(slot.wrappedValue.path)

            Text(slot.wrappedValue.original)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(slot.wrappedValue.original)

            if slot.wrappedValue.enabled {
                Picker("", selection: slot.strategy) {
                    ForEach(MutationStrategy.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .labelsHidden()
                .frame(width: 110)
                .controlSize(.small)
                .disabled(runner.isRunning)
                .help(slot.wrappedValue.strategy.explanation)

                Text(runner.isRunning ? "sending…" : runner.preview(slot.wrappedValue))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.green)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(width: 130, alignment: .leading)
                    .help("A fresh sample of what will be sent")
            } else {
                Color.clear.frame(width: 247, height: 1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private func sourceColor(_ source: FieldSource) -> Color {
        switch source {
        case .header: return .blue
        case .query:  return .teal
        case .json:   return .purple
        case .form:   return .indigo
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    private func numberField(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            fieldLabel(title)
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .frame(width: 72)
                .disabled(runner.isRunning)
        }
    }

    private func ms(_ value: Double) -> String {
        value == 0 ? "—" : String(format: "%.0f ms", value)
    }

    private func stat(_ title: String, _ value: String, tint: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title.uppercased())
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(tint)
                .monospacedDigit()
        }
        .frame(minWidth: 56, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.07)))
    }

    // MARK: Results

    private var resultsPane: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                sectionHeader(showStages ? "Stages" : "Hits") {
                    if runner.stages.count > 1 {
                        Picker("", selection: $showStages) {
                            Text("Hits").tag(false)
                            Text("Stages").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 112)
                        .controlSize(.small)
                    }
                }

                if runner.results.isEmpty {
                    emptyState("No hits yet", "Press Start (⌘↩)")
                } else if showStages && runner.stages.count > 1 {
                    List {
                        ForEach(runner.stages) { stage in
                            stageRow(stage)
                        }
                    }
                    .listStyle(.inset(alternatesRowBackgrounds: true))
                } else {
                    List(selection: $runner.selected) {
                        ForEach(runner.results) { hit in
                            hitRow(hit).tag(hit.id)
                        }
                    }
                    .listStyle(.inset(alternatesRowBackgrounds: true))
                }
            }
            .frame(minWidth: 320, idealWidth: 400)

            VStack(alignment: .leading, spacing: 0) {
                sectionHeader(showRequest ? "Request sent" : "Response") {
                    HStack(spacing: 9) {
                        if let hit = runner.selectedResult {
                            Text(showRequest ? "#\(hit.index)" : "#\(hit.index) · \(hit.byteCount) bytes")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)

                            Picker("", selection: $showRequest) {
                                Text("Response").tag(false)
                                Text("Request").tag(true)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(width: 142)
                            .controlSize(.small)
                            .help("Switch between what came back and what was sent")

                            if !showRequest {
                                Toggle("Headers", isOn: $showHeaders)
                                    .toggleStyle(.checkbox)
                                    .font(.system(size: 11))
                            }
                            Button("Copy") {
                                showRequest ? runner.copySentRequest() : runner.copyResponse()
                            }
                            .buttonStyle(.link)
                            .font(.system(size: 11))
                        }
                    }
                }
                ScrollView {
                    Text(showRequest ? requestText : responseText)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(9)
                }
                .background(Color(nsColor: .textBackgroundColor))
            }
            .frame(minWidth: 320)
        }
        .frame(minHeight: 220)
    }

    private func hitRow(_ hit: HitResult) -> some View {
        HStack(spacing: 8) {
            Text("#\(hit.index)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .leading)
            Text(hit.statusLabel)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(color(for: hit), in: Capsule())
            Text(String(format: "%.0f ms", hit.milliseconds))
                .font(.system(size: 11, design: .monospaced))
                .monospacedDigit()
            Spacer(minLength: 6)
            Text(Self.clock.string(from: hit.startedAt))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 1)
    }

    private func stageRow(_ stage: Runner.StageSummary) -> some View {
        HStack(spacing: 8) {
            Text("x\(stage.parallel)")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .frame(width: 34, alignment: .leading)
                .help("Requests in flight at once")

            Text("\(stage.ok)/\(stage.sent)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(stage.ok == stage.sent ? .primary : .secondary)
                .frame(width: 52, alignment: .leading)

            if stage.rateLimited > 0 {
                tag("429 x\(stage.rateLimited)", .purple)
            }
            if stage.serverErrors > 0 {
                tag("5xx x\(stage.serverErrors)", .red)
            }
            if stage.transportFailures > 0 {
                tag("err x\(stage.transportFailures)", .red)
            }

            Spacer(minLength: 4)

            Text(String(format: "p95 %.0fms", stage.p95Ms))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(String(format: "%.1f r/s", stage.reqPerSec))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .frame(width: 62, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }

    private func tag(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color, in: Capsule())
    }

    private func color(for hit: HitResult) -> Color { codeColor(hit.statusCode) }

    private func codeColor(_ code: Int) -> Color {
        switch code {
        case 0:         return .red
        case 200..<300: return .green
        case 300..<400: return .teal
        case 429:       return .purple   // the one everyone is actually looking for
        case 400..<500: return .orange
        default:        return .red
        }
    }

    private func sectionHeader<Trailing: View>(_ title: String,
                                               @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            trailing()
        }
        .padding(.horizontal, 11)
        .padding(.top, 7)
        .padding(.bottom, 5)
    }

    private func emptyState(_ title: String, _ subtitle: String) -> some View {
        VStack(spacing: 3) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            Text(subtitle).font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// What actually went out for the selected hit — the point being that in
    /// Advanced mode every hit sends something different.
    private var requestText: String {
        guard let hit = runner.selectedResult else {
            return "Select a hit to see the request it sent."
        }
        var out = "\(hit.sentMethod) \(hit.sentURL)"
        if !hit.sentHeaders.isEmpty {
            out += "\n\n" + hit.sentHeaders.map { "\($0.0): \($0.1)" }.joined(separator: "\n")
        }
        if let body = hit.sentBody, !body.isEmpty {
            out += "\n\n" + prettyJSON(body)
        }
        if let mutations = hit.mutations {
            out += "\n\nrandomised → \(mutations)"
        }
        return out
    }

    private var responseText: String {
        guard let hit = runner.selectedResult else {
            return "Select a hit to see its response."
        }
        var out: [String] = []
        if let err = hit.errorText { out.append("⚠︎ \(err)") }
        if let mutations = hit.mutations { out.append("randomised → \(mutations)") }
        if showHeaders && !hit.responseHeaders.isEmpty {
            out.append(hit.responseHeaders.map { "\($0.0): \($0.1)" }.joined(separator: "\n"))
        }
        out.append(hit.body.isEmpty ? "(empty body)" : prettyJSON(hit.body))
        return out.joined(separator: "\n\n")
    }

    /// Pretty-prints JSON responses; anything else is shown untouched.
    private func prettyJSON(_ raw: String) -> String {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: object,
                                                       options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: pretty, encoding: .utf8)
        else { return raw }
        return text
    }

    // MARK: Status bar

    private var statusBar: some View {
        HStack(spacing: 6) {
            if !runner.status.isEmpty {
                Image(systemName: runner.statusIsError ? "exclamationmark.triangle.fill" : "info.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(runner.statusIsError ? .orange : .secondary)
                Text(runner.status)
                    .font(.system(size: 11))
                    .foregroundStyle(runner.statusIsError ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text("⌘↩ start · ⌘. stop")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
