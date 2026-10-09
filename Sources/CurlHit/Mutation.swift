import Foundation

// MARK: - Where a mutable value lives in the request

enum FieldSource: String, Codable {
    case header, query, json, form

    var label: String {
        switch self {
        case .header: return "header"
        case .query:  return "query"
        case .json:   return "body"
        case .form:   return "form"
        }
    }
}

/// One step of a JSON key path: `user.addresses[0].city`.
enum PathStep: Hashable {
    case key(String)
    case index(Int)
}

// MARK: - How a value is regenerated for each request

enum MutationStrategy: String, CaseIterable, Identifiable {
    case sameShape
    case uuid
    case digits
    case hex
    case sequence
    case timestamp

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sameShape: return "Same shape"
        case .uuid:      return "UUID"
        case .digits:    return "Digits"
        case .hex:       return "Hex"
        case .sequence:  return "Sequence"
        case .timestamp: return "Timestamp"
        }
    }

    var explanation: String {
        switch self {
        case .sameShape: return "Same length, same character classes — digits stay digits, letters stay letters, separators are kept."
        case .uuid:      return "A fresh UUID each request, matching the original's case and dash style."
        case .digits:    return "Random digits, same length as the original."
        case .hex:       return "Random hex, same length and case as the original."
        case .sequence:  return "The hit number, left-padded to the original's length."
        case .timestamp: return "Milliseconds since the epoch at the moment of sending."
        }
    }
}

enum Mutator {

    /// Keeps the value's shape so server-side validation still passes: a 32-character
    /// hex token stays 32 hex characters, `+91-98765-43210` keeps its dashes.
    static func sameShape(_ original: String) -> String {
        guard !original.isEmpty else { return original }

        // Treat an all-hex value as hex, so tokens and ids stay parseable.
        let lowerHex = CharacterSet(charactersIn: "0123456789abcdef")
        let upperHex = CharacterSet(charactersIn: "0123456789ABCDEF")
        let scalars = CharacterSet(charactersIn: original)
        if original.count >= 8, lowerHex.isSuperset(of: scalars) {
            return randomHex(length: original.count, uppercase: false)
        }
        if original.count >= 8, upperHex.isSuperset(of: scalars) {
            return randomHex(length: original.count, uppercase: true)
        }

        return String(original.map { ch -> Character in
            if ch.isNumber { return Character(String(Int.random(in: 0...9))) }
            if ch.isLetter && ch.isLowercase { return "abcdefghijklmnopqrstuvwxyz".randomElement()! }
            if ch.isLetter && ch.isUppercase { return "ABCDEFGHIJKLMNOPQRSTUVWXYZ".randomElement()! }
            return ch               // dashes, dots, @, spaces: left alone
        })
    }

    static func randomHex(length: Int, uppercase: Bool) -> String {
        let alphabet = uppercase ? "0123456789ABCDEF" : "0123456789abcdef"
        return String((0..<length).map { _ in alphabet.randomElement()! })
    }

    static func randomDigits(length: Int) -> String {
        guard length > 0 else { return "" }
        return String((0..<length).map { _ in "0123456789".randomElement()! })
    }

    static func apply(_ strategy: MutationStrategy, to original: String, hit: Int) -> String {
        switch strategy {
        case .sameShape:
            return sameShape(original)
        case .uuid:
            let fresh = UUID().uuidString
            let keepsDashes = original.contains("-")
            let body = keepsDashes ? fresh : fresh.replacingOccurrences(of: "-", with: "")
            // Match the original's case where it is unambiguous.
            return original == original.lowercased() ? body.lowercased() : body
        case .digits:
            return randomDigits(length: max(1, original.count))
        case .hex:
            let isUpper = original.rangeOfCharacter(from: CharacterSet(charactersIn: "ABCDEF")) != nil
            return randomHex(length: max(1, original.count), uppercase: isUpper)
        case .sequence:
            let text = String(hit)
            guard text.count < original.count else { return text }
            return String(repeating: "0", count: original.count - text.count) + text
        case .timestamp:
            return String(Int(Date().timeIntervalSince1970 * 1000))
        }
    }
}

// MARK: - A field the user can choose to randomise

struct FieldSlot: Identifiable, Hashable {
    let id: String                  // stable across re-analysis, e.g. "json:user.id"
    let source: FieldSource
    let path: String                // header name, query key, or JSON/form key path
    let original: String
    let steps: [PathStep]           // JSON only
    let isNumeric: Bool             // JSON only: emit a number, not a string

    var enabled: Bool = false
    var strategy: MutationStrategy = .sameShape

    func value(forHit hit: Int) -> String {
        Mutator.apply(strategy, to: original, hit: hit)
    }

    static func == (a: FieldSlot, b: FieldSlot) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - The request, taken apart so it can be rebuilt per hit

struct RequestTemplate {

    enum Body {
        case none
        case raw(Data)
        case json(Any)
        case form([(String, String)])
    }

    let parsed: ParsedRequest
    let body: Body
    let slots: [FieldSlot]

    // MARK: Taking it apart

    static func analyse(_ parsed: ParsedRequest) -> RequestTemplate {
        var slots: [FieldSlot] = []

        for (name, value) in parsed.headers where !value.isEmpty {
            slots.append(FieldSlot(id: "header:\(name)", source: .header, path: name,
                                   original: value, steps: [], isNumeric: false))
        }

        if let components = URLComponents(url: parsed.url, resolvingAgainstBaseURL: false),
           let items = components.queryItems {
            for item in items {
                let value = item.value ?? ""
                guard !value.isEmpty else { continue }
                slots.append(FieldSlot(id: "query:\(item.name)", source: .query, path: item.name,
                                       original: value, steps: [], isNumeric: false))
            }
        }

        let body = decodeBody(parsed)
        switch body {
        case .json(let object):
            collectJSON(object, steps: [], display: "", into: &slots)
        case .form(let pairs):
            for (name, value) in pairs where !value.isEmpty {
                slots.append(FieldSlot(id: "form:\(name)", source: .form, path: name,
                                       original: value, steps: [], isNumeric: false))
            }
        case .none, .raw:
            break
        }

        return RequestTemplate(parsed: parsed, body: body, slots: slots)
    }

    private static func decodeBody(_ parsed: ParsedRequest) -> Body {
        guard let data = parsed.body, !data.isEmpty else { return .none }

        if let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
           object is [String: Any] || object is [Any] {
            return .json(object)
        }

        if let text = String(data: data, encoding: .utf8), text.contains("=") {
            let pairs: [(String, String)] = text.split(separator: "&").map { chunk in
                let bits = chunk.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let key = String(bits.first ?? "")
                let value = bits.count > 1 ? String(bits[1]) : ""
                return (key.removingPercentEncoding ?? key, value.removingPercentEncoding ?? value)
            }
            if !pairs.isEmpty { return .form(pairs) }
        }

        return .raw(data)
    }

    private static func collectJSON(_ node: Any, steps: [PathStep], display: String,
                                    into slots: inout [FieldSlot]) {
        if let dict = node as? [String: Any] {
            for key in dict.keys.sorted() {
                let child = display.isEmpty ? key : "\(display).\(key)"
                collectJSON(dict[key]!, steps: steps + [.key(key)], display: child, into: &slots)
            }
            return
        }
        if let array = node as? [Any] {
            for (i, element) in array.enumerated() {
                collectJSON(element, steps: steps + [.index(i)], display: "\(display)[\(i)]", into: &slots)
            }
            return
        }

        // Scalars. Booleans and null are skipped — randomising them is meaningless.
        if let number = node as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return }
            slots.append(FieldSlot(id: "json:\(display)", source: .json, path: display,
                                   original: number.stringValue, steps: steps, isNumeric: true))
            return
        }
        if let text = node as? String, !text.isEmpty {
            slots.append(FieldSlot(id: "json:\(display)", source: .json, path: display,
                                   original: text, steps: steps, isNumeric: false))
        }
    }

    // MARK: Putting it back together, once per request

    /// Builds the request for hit `n`, applying every enabled slot. Also returns a
    /// short note of what was changed, so the result list can show it.
    func request(forHit hit: Int, slots active: [FieldSlot],
                 defaultTimeout: Double) -> (URLRequest, String?) {
        let enabled = active.filter(\.enabled)
        guard !enabled.isEmpty else {
            return (parsed.urlRequest(defaultTimeout: defaultTimeout), nil)
        }

        var generated: [String: String] = [:]
        for slot in enabled { generated[slot.id] = slot.value(forHit: hit) }

        var url = parsed.url
        let queryChanges = enabled.filter { $0.source == .query }
        if !queryChanges.isEmpty,
           var components = URLComponents(url: parsed.url, resolvingAgainstBaseURL: false) {
            components.queryItems = components.queryItems?.map { item in
                if let slot = queryChanges.first(where: { $0.path == item.name }) {
                    return URLQueryItem(name: item.name, value: generated[slot.id])
                }
                return item
            }
            url = components.url ?? parsed.url
        }

        var request = URLRequest(url: url)
        request.httpMethod = parsed.method
        request.timeoutInterval = parsed.timeout ?? defaultTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData

        for (name, value) in parsed.headers {
            if let slot = enabled.first(where: { $0.source == .header && $0.path == name }) {
                request.setValue(generated[slot.id], forHTTPHeaderField: name)
            } else {
                request.setValue(value, forHTTPHeaderField: name)
            }
        }

        switch body {
        case .none:
            break
        case .raw(let data):
            request.httpBody = data
        case .json(let object):
            var mutated = object
            for slot in enabled where slot.source == .json {
                let replacement: Any = slot.isNumeric
                    ? (NSDecimalNumber(string: generated[slot.id]) as NSNumber)
                    : (generated[slot.id] ?? slot.original)
                mutated = Self.setJSON(mutated, steps: slot.steps, value: replacement)
            }
            request.httpBody = try? JSONSerialization.data(withJSONObject: mutated,
                                                           options: [.fragmentsAllowed])
        case .form(let pairs):
            let rebuilt = pairs.map { name, value -> String in
                let slot = enabled.first { $0.source == .form && $0.path == name }
                let final = slot.flatMap { generated[$0.id] } ?? value
                return "\(percentEncode(name))=\(percentEncode(final))"
            }
            request.httpBody = Data(rebuilt.joined(separator: "&").utf8)
        }

        let note = enabled
            .sorted { $0.path < $1.path }
            .map { "\($0.path)=\(generated[$0.id] ?? "")" }
            .joined(separator: "  ")
        return (request, note)
    }

    private static func setJSON(_ node: Any, steps: [PathStep], value: Any) -> Any {
        guard let step = steps.first else { return value }
        let rest = Array(steps.dropFirst())

        switch step {
        case .key(let key):
            guard var dict = node as? [String: Any], let child = dict[key] else { return node }
            dict[key] = setJSON(child, steps: rest, value: value)
            return dict
        case .index(let i):
            guard var array = node as? [Any], array.indices.contains(i) else { return node }
            array[i] = setJSON(array[i], steps: rest, value: value)
            return array
        }
    }

    private func percentEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}
