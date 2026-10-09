import Foundation

/// A curl command (or a bare URL) translated into something `URLSession` can send.
struct ParsedRequest {
    var url: URL
    var method: String
    var headers: [(String, String)]
    var body: Data?
    var insecure: Bool
    var followRedirects: Bool
    var timeout: Double?
    var warnings: [String]

    func urlRequest(defaultTimeout: Double) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = timeout ?? defaultTimeout
        req.httpBody = body
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.cachePolicy = .reloadIgnoringLocalCacheData
        return req
    }
}

enum CurlParseError: LocalizedError {
    case empty
    case noURL
    case badURL(String)

    var errorDescription: String? {
        switch self {
        case .empty:        return "Nothing to send — paste a curl command or a URL."
        case .noURL:        return "No URL found in that command."
        case .badURL(let s): return "“\(s)” is not a valid URL."
        }
    }
}

struct CurlParser {

    // MARK: Shell-ish tokenizer

    /// Splits a pasted command the way a shell would: honours ' ", backslash escapes
    /// and `\` line continuations, so multi-line curl pastes work as-is.
    static func tokenize(_ input: String) -> [String] {
        enum Mode { case normal, single, double }
        var mode = Mode.normal
        var out: [String] = []
        var cur = ""
        var started = false
        var i = input.startIndex

        func flush() {
            if started { out.append(cur); cur = ""; started = false }
        }

        while i < input.endIndex {
            let c = input[i]
            switch mode {
            case .normal:
                if c == "'" {
                    mode = .single; started = true
                } else if c == "\"" {
                    mode = .double; started = true
                } else if c == "\\" {
                    let j = input.index(after: i)
                    if j < input.endIndex {
                        let n = input[j]
                        if n != "\n" && n != "\r" { cur.append(n); started = true }
                        i = j
                    }
                } else if c == " " || c == "\t" || c == "\n" || c == "\r" {
                    flush()
                } else {
                    cur.append(c); started = true
                }
            case .single:
                if c == "'" { mode = .normal } else { cur.append(c) }
            case .double:
                if c == "\"" {
                    mode = .normal
                } else if c == "\\" {
                    let j = input.index(after: i)
                    if j < input.endIndex {
                        let n = input[j]
                        if n == "\"" || n == "\\" || n == "$" || n == "`" {
                            cur.append(n); i = j
                        } else if n == "\n" || n == "\r" {
                            i = j
                        } else {
                            cur.append(c)
                        }
                    } else { cur.append(c) }
                } else {
                    cur.append(c)
                }
            }
            i = input.index(after: i)
        }
        flush()
        return out
    }

    // MARK: Flag tables

    /// Short flags that consume a value (`-H x`, and also the glued `-XPOST` form).
    private static let shortWithValue: Set<Character> = ["X", "H", "d", "F", "u", "b", "A", "e", "m", "o", "w", "D", "T", "x", "E", "c", "C", "Y", "z"]
    /// Short flags we accept and ignore (output/progress/verbosity concerns).
    private static let shortIgnored: Set<Character> = ["s", "S", "v", "i", "#", "f", "N", "g", "j", "q", "0", "a", "B", "R", "O", "J", "p", "Z"]

    /// Long flags that consume a value but mean nothing to us.
    private static let longIgnoredWithValue: Set<String> = [
        "--output", "--write-out", "--dump-header", "--trace", "--trace-ascii",
        "--retry", "--retry-delay", "--retry-max-time", "--proxy", "--cert",
        "--key", "--cacert", "--capath", "--limit-rate", "--cookie-jar",
        "--resolve", "--interface", "--stderr", "--upload-file", "--config"
    ]
    /// Long flags that take no value and mean nothing to us.
    private static let longIgnored: Set<String> = [
        "--silent", "--show-error", "--verbose", "--include", "--compressed",
        "--no-buffer", "--fail", "--fail-with-body", "--globoff", "--progress-bar",
        "--no-progress-meter", "--tlsv1.2", "--tlsv1.3", "--http1.1", "--http2",
        "--http2-prior-knowledge", "--http3", "--ipv4", "--ipv6", "--remote-name",
        "--remote-header-name", "--create-dirs", "--path-as-is", "--raw",
        "--disable", "--anyauth", "--basic", "--digest", "--ntlm", "--negotiate",
        "--no-keepalive", "--tcp-nodelay", "--trace-time", "--parallel"
    ]

    // MARK: Parse

    static func parse(_ raw: String) throws -> ParsedRequest {
        var tokens = tokenize(raw)
        if let first = tokens.first,
           first.lowercased() == "curl" || first.lowercased().hasSuffix("/curl") {
            tokens.removeFirst()
        }
        guard !tokens.isEmpty else { throw CurlParseError.empty }

        var urlString: String?
        var method: String?
        var headers: [(String, String)] = []
        var dataParts: [String] = []
        var formParts: [String] = []
        var user: String?
        var cookie: String?
        var insecure = false
        var follow = false
        var forceGet = false
        var headOnly = false
        var timeout: Double?
        var jsonBody: String?
        var warnings: [String] = []

        // Expand `-sL` → `-s -L` and `-XPOST` → `-X POST` so one loop handles everything.
        var queue: [String] = []
        for t in tokens {
            if t.count > 2, t.hasPrefix("-"), !t.hasPrefix("--") {
                var chars = Array(t.dropFirst())
                var expanded: [String] = []
                var consumedRest = false
                while let c = chars.first {
                    chars.removeFirst()
                    if shortWithValue.contains(c) {
                        expanded.append("-\(c)")
                        if !chars.isEmpty { expanded.append(String(chars)); consumedRest = true }
                        break
                    } else if shortIgnored.contains(c) || c == "k" || c == "L" || c == "G" || c == "I" {
                        expanded.append("-\(c)")
                    } else {
                        // Not a recognisable cluster — treat the whole token verbatim.
                        expanded = [t]
                        consumedRest = true
                        break
                    }
                }
                if !consumedRest && !chars.isEmpty { expanded.append("-" + String(chars)) }
                queue.append(contentsOf: expanded)
            } else {
                queue.append(t)
            }
        }

        var idx = 0
        func nextValue(_ flag: String) -> String? {
            guard idx + 1 < queue.count else { warnings.append("\(flag) had no value."); return nil }
            idx += 1
            return queue[idx]
        }

        while idx < queue.count {
            var tok = queue[idx]
            var inlineValue: String?

            // `--header=value` form
            if tok.hasPrefix("--"), let eq = tok.firstIndex(of: "=") {
                inlineValue = String(tok[tok.index(after: eq)...])
                tok = String(tok[tok.startIndex..<eq])
            }
            func value(_ flag: String) -> String? { inlineValue ?? nextValue(flag) }

            switch tok {
            case "-X", "--request":
                if let v = value(tok) { method = v.uppercased() }
            case "-H", "--header":
                if let v = value(tok) {
                    if let colon = v.firstIndex(of: ":") {
                        let k = String(v[v.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
                        let val = String(v[v.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                        if !k.isEmpty { headers.append((k, val)) }
                    } else {
                        warnings.append("Ignored malformed header “\(v)”.")
                    }
                }
            case "-d", "--data", "--data-raw", "--data-ascii", "--data-binary":
                if let v = value(tok) { dataParts.append(v) }
            case "--data-urlencode":
                if let v = value(tok) {
                    if let eq = v.firstIndex(of: "=") {
                        let name = String(v[v.startIndex..<eq])
                        let val = String(v[v.index(after: eq)...])
                        dataParts.append("\(name)=\(percentEncode(val))")
                    } else {
                        dataParts.append(percentEncode(v))
                    }
                }
            case "--json":
                if let v = value(tok) { jsonBody = v }
            case "-F", "--form", "--form-string":
                if let v = value(tok) { formParts.append(v) }
            case "-u", "--user":
                if let v = value(tok) { user = v }
            case "-b", "--cookie":
                if let v = value(tok) { cookie = v }
            case "-A", "--user-agent":
                if let v = value(tok) { headers.append(("User-Agent", v)) }
            case "-e", "--referer":
                if let v = value(tok) { headers.append(("Referer", v)) }
            case "-m", "--max-time", "--connect-timeout":
                if let v = value(tok), let d = Double(v) { timeout = d }
            case "--url":
                if let v = value(tok) { urlString = v }
            case "-k", "--insecure":
                insecure = true
            case "-L", "--location", "--location-trusted":
                follow = true
            case "-G", "--get":
                forceGet = true
            case "-I", "--head":
                headOnly = true
            default:
                if longIgnoredWithValue.contains(tok) {
                    _ = value(tok)
                } else if longIgnored.contains(tok) {
                    break
                } else if tok.count == 2, tok.hasPrefix("-"), let c = tok.last {
                    if shortIgnored.contains(c) { break }
                    if shortWithValue.contains(c) { _ = value(tok); break }
                    warnings.append("Ignored unknown flag \(tok).")
                } else if tok.hasPrefix("-") && tok != "-" {
                    warnings.append("Ignored unknown flag \(tok).")
                } else {
                    if urlString == nil { urlString = tok }
                    else { warnings.append("Ignored extra argument “\(tok)”.") }
                }
            }
            idx += 1
        }

        guard var rawURL = urlString, !rawURL.isEmpty else { throw CurlParseError.noURL }
        if !rawURL.lowercased().hasPrefix("http://") && !rawURL.lowercased().hasPrefix("https://") {
            rawURL = "https://" + rawURL
        }

        var body: Data?
        var bodyImpliesPost = false

        if let json = jsonBody {
            body = Data(json.utf8)
            bodyImpliesPost = true
            if !headers.contains(where: { $0.0.lowercased() == "content-type" }) {
                headers.append(("Content-Type", "application/json"))
            }
            if !headers.contains(where: { $0.0.lowercased() == "accept" }) {
                headers.append(("Accept", "application/json"))
            }
        } else if !formParts.isEmpty {
            let boundary = "----CurlHitBoundary\(UUID().uuidString)"
            body = multipartBody(formParts, boundary: boundary, warnings: &warnings)
            bodyImpliesPost = true
            headers.removeAll { $0.0.lowercased() == "content-type" }
            headers.append(("Content-Type", "multipart/form-data; boundary=\(boundary)"))
        } else if !dataParts.isEmpty {
            let joined = dataParts.joined(separator: "&")
            if forceGet {
                rawURL = appendQuery(joined, to: rawURL)
            } else {
                body = Data(joined.utf8)
                bodyImpliesPost = true
                if !headers.contains(where: { $0.0.lowercased() == "content-type" }) {
                    headers.append(("Content-Type", "application/x-www-form-urlencoded"))
                }
            }
        }

        guard let url = URL(string: rawURL) else { throw CurlParseError.badURL(rawURL) }

        if let user {
            let encoded = Data(user.utf8).base64EncodedString()
            headers.append(("Authorization", "Basic \(encoded)"))
        }
        if let cookie {
            headers.append(("Cookie", cookie))
        }

        let resolvedMethod: String = {
            if headOnly { return "HEAD" }
            if let m = method { return m }
            if forceGet { return "GET" }
            return bodyImpliesPost ? "POST" : "GET"
        }()

        return ParsedRequest(url: url,
                             method: resolvedMethod,
                             headers: headers,
                             body: body,
                             insecure: insecure,
                             followRedirects: follow,
                             timeout: timeout,
                             warnings: warnings)
    }

    // MARK: Helpers

    private static func percentEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    private static func appendQuery(_ query: String, to urlString: String) -> String {
        guard !query.isEmpty else { return urlString }
        return urlString.contains("?") ? "\(urlString)&\(query)" : "\(urlString)?\(query)"
    }

    private static func multipartBody(_ parts: [String], boundary: String, warnings: inout [String]) -> Data {
        var data = Data()
        for part in parts {
            guard let eq = part.firstIndex(of: "=") else {
                warnings.append("Ignored malformed form field “\(part)”.")
                continue
            }
            let name = String(part[part.startIndex..<eq])
            var value = String(part[part.index(after: eq)...])

            data.append(Data("--\(boundary)\r\n".utf8))

            if value.hasPrefix("@") || value.hasPrefix("<") {
                let spec = String(value.dropFirst())
                let path = spec.split(separator: ";").first.map(String.init) ?? spec
                let expanded = (path as NSString).expandingTildeInPath
                if let fileData = FileManager.default.contents(atPath: expanded) {
                    let filename = (expanded as NSString).lastPathComponent
                    data.append(Data("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".utf8))
                    data.append(Data("Content-Type: application/octet-stream\r\n\r\n".utf8))
                    data.append(fileData)
                    data.append(Data("\r\n".utf8))
                    continue
                }
                warnings.append("Could not read form file “\(path)” (sandboxed apps need you to open it once).")
                value = ""
            }

            data.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
            data.append(Data("\(value)\r\n".utf8))
        }
        data.append(Data("--\(boundary)--\r\n".utf8))
        return data
    }
}
