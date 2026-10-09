# Curl Hit

A small native macOS app that replays a `curl` command as many times as you like, in
parallel if you want, and shows you what came back.

It was built for one question — *where does my API start pushing back?* — so alongside
plain repeat-and-inspect it can climb through concurrency levels and tell you where the
429s begin.

- **Native and small** — SwiftUI + AppKit only. ~1.9 MB, no bundled frameworks, no Electron, no runtime dependencies.
- **Local only** — no database, no accounts, no telemetry. The only thing written to disk is your last-used inputs.
- **Sandboxed** — App Sandbox on, with exactly one entitlement: outgoing network.
- **Reads real curl** — headers, methods, bodies, auth, cookies, multi-line `\` pastes.
- **Advanced mode** — takes the request apart and randomises chosen headers, query parameters or body fields on every hit, keeping each value's shape.

---

## Install

```bash
git clone https://github.com/gulsher7/macos-curl-hit.git
cd macos-curl-hit
./build.sh
open build/CurlHit.app
```

`build.sh` needs only the Swift compiler from Xcode or the Command Line Tools — no Xcode
project, no package fetch, nothing to install. To keep it around:

```bash
cp -R build/CurlHit.app /Applications/
```

Requires macOS 13 Ventura or later.

---

## Quick start

The app opens on a harmless public example — 5 requests, one second apart:

```
https://thesimpsonsapi.com/api/characters
```

Press **Start** (`⌘↩`). Replace it with your own request whenever you like; a complete
curl command works as pasted:

```bash
curl -X POST 'https://example.com/api/login' \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer <token>' \
  --data-raw '{"email":"you@example.com","password":"secret"}'
```

---

## Features

### Request — paste a curl, or just a URL

The **Request** box accepts either. A bare URL is fine (`https://` is assumed if you
leave off the scheme), and so is a full curl command copied out of your browser's
network tab or your terminal history.

Multi-line pastes with trailing `\` work as-is — no need to flatten them onto one line.
Quoting is handled the way a shell would: single quotes, double quotes and backslash
escapes all behave as expected, so a JSON body full of `"` survives the trip.

The command is translated into a real `URLRequest`. The app does **not** shell out to
`/usr/bin/curl`, which matters for two reasons: sandboxed apps can't spawn outside
binaries, and parsing means the app knows exactly what it is about to send.

### Count and Interval — how many, how fast

**Count** is how many requests to send, up to 100,000.

**Interval** is the delay *between* them, in milliseconds or seconds (toggle included).
`0` fires them back to back. In parallel runs the interval applies between waves rather
than between individual requests.

### Timeout

Per-request timeout in seconds. If the pasted curl carries its own `-m` / `--max-time`,
that wins — the field is a default, not an override.

### Stop on failure

Halts the whole run the moment anything comes back outside 2xx/3xx. Useful when you are
checking "does this ever fail" rather than "how often does it fail", and it stops you
hammering an endpoint that is already broken.

### Parallel — requests in flight at once

Raise **Parallel** above 1 and requests go out in waves: that many fire together, the
wave is awaited, then the interval applies before the next one. `Count 100`,
`Parallel 10`, `Interval 0` means ten waves of ten, back to back.

Capped at 50, deliberately — see [Using it responsibly](#using-it-responsibly).

> One implementation note that affects your numbers: `URLSession` limits connections to
> a single host to 6 by default. The app raises that limit to match your Parallel
> setting, so "20 parallel" really is 20 in flight. Without it, requests would quietly
> queue at 6 and you would be measuring your own client instead of the server.

### Ramp mode — find the limit instead of guessing it

"Ramp" is the load-testing term for increasing load step by step rather than all at once.

In **Fixed** mode you choose one concurrency level and learn whether it breaks. In
**Ramp** mode the app climbs a ladder of levels and tells you *where* it breaks — which
is usually the number you actually wanted.

Set **Parallel levels** to the ladder (`1, 2, 5, 10, 20`; up to 12 rungs, each capped at
50) and **Per level** to how many requests to send at each rung. The **Stages** tab then
shows one row per level:

```
stage  sent   ok   429   p95      req/s
x1     16     16   0     166ms    6.4
x4     16     16   0     158ms    25.4
x8     16     16   0     160ms    50.1
x16    16     8    8     165ms    96.9

Rate limited at 16 parallel — 8/16 got 429.
```

That last line is the point of the mode. It separates four situations that look similar
in a results list but call for completely different fixes:

| What the ramp sees | What it means |
| --- | --- |
| **429s appear** | A configured quota. The verdict names the level where they start. |
| **5xx or dropped connections** | The server is breaking under load, not throttling. |
| **No errors, but p95 past 2× baseline** | Queuing. You found the concurrency where it falls behind — a capacity finding, not a limit, and raising a rate-limit config won't help. |
| **Nothing bends** | No limit up to the top rung, reported with the peak throughput reached. |

If you are probing a **per-minute** quota rather than a per-concurrency one, give the
run an interval of a few seconds so throttling from one rung doesn't bleed into the next.

### Advanced mode — a different value on every request

Switch the toggle in the title bar from **Simple** to **Advanced** and the app pulls your
request apart: every header, every query parameter and every field in the body, including
nested JSON, becomes a row you can switch on.

```
 ☑  header   X-Device-Id     7F3A1B20-44C1-4E8A-…   Same shape ▾   5P2X6D66-88J6-3R5V-…
 ☐  header   Content-Type    application/json
 ☑  query    trace           abc123def456           Same shape ▾   76b34b9c5c6f
 ☑  body     user.id         48217                  Digits     ▾   35286
 ☑  body     user.email      someone@example.com    Same shape ▾   kzjtqfr@qykirmn.lcv
 ☑  body     token           ca8b7d1d1ae846cbbf99…  Hex        ▾   f6bb494ef9cef0f0…
```

Each switched-on field gets a fresh value for **every single request**, with a live
preview of what will be sent. This is what you want when the endpoint rejects duplicates,
dedupes on a device id, caches on a query parameter, or when you need a thousand distinct
signups rather than the same one a thousand times.

**Strategies**

| Strategy | What it generates |
| --- | --- |
| **Same shape** | Same length, same character classes. Digits stay digits, letters stay letters, and separators like `-`, `.` and `@` are left in place |
| **UUID** | A fresh UUID per request, matching the original's case and dash style |
| **Digits** | Random digits, same length |
| **Hex** | Random hex, same length and case |
| **Sequence** | The hit number, zero-padded to the original's length — useful for idempotency keys |
| **Timestamp** | Milliseconds since the epoch at the moment of sending |

**Same shape** is the default, and the reason is worth knowing: if a server validates
"32 hex characters" or "numeric id", a value of random mixed characters gets rejected by
the validator and you end up testing the validator instead of the endpoint. Preserving
the shape keeps the request realistic. A 32-character hex token stays 32 hex characters;
`+91-98765-43210` keeps its dashes; `25.3.2` keeps its dots.

Types are preserved too — a JSON number stays a JSON number rather than becoming a
quoted string, so strict backends don't reject the body outright.

Each result records what was randomised for it, shown above the response body and
included in the CSV export, so a failure can always be traced back to the exact values
that caused it.

### The numbers

Across the top of the results:

| Stat | What it tells you |
| --- | --- |
| **Sent** | Requests completed so far |
| **OK** | 2xx and 3xx responses |
| **Failed** | Everything else, including connections that never completed |
| **Avg** | Mean response time |
| **p95** | 95th-percentile response time — the one that exposes throttling and queuing long before the average moves |
| **Max** | Slowest single response |
| **Req/s** | Completed requests per second of wall clock. This should climb as you raise Parallel; when it stops climbing, you have found a ceiling |

### Status breakdown

A chip per status code — `200 x85` `429 x15` — so you can see the shape of a run at a
glance instead of scrolling. **429 gets its own colour** (purple) because it is usually
the one you are hunting.

### Rate-limit headers

If the server sends `Retry-After`, `X-RateLimit-*` or the RFC-style `RateLimit-*`
headers, the most recent values are surfaced under the progress bar automatically. No
need to open a response and hunt for them.

### Per-hit results and the response viewer

Every request is listed with its number, status code, duration and wall-clock time,
colour-coded by status class. Waves finish out of order, so results are sorted by hit
number rather than by arrival — the list stays readable.

Select any hit to see its body in the right-hand pane. **JSON is pretty-printed**
automatically; anything else is shown untouched. The **Headers** toggle adds the
response headers above the body, and **Copy** puts the whole thing on the clipboard.

Bodies are truncated in the viewer at 200,000 characters, with a note giving the real
size.

### Copy CSV

Puts the entire run on the clipboard, ready for a spreadsheet:

```
hit,parallel,status,ms,bytes,started_at,error,randomised
1,4,200,163.2,8275,2026-10-09T09:31:02Z,"","trace=76b34b9c5c6f  user.id=35286"
```

The `parallel` column records the level each hit ran at, so a ramp run can be grouped and
charted afterwards. The `randomised` column records the exact values Advanced mode
generated for that hit.

### Your inputs are remembered

Everything you type is restored on next launch, via `UserDefaults`. No file is created,
no database, nothing to clean up.

> **A caution:** this includes the Request box. If you paste a curl containing a token,
> that token is written to the preferences plist in plain text. Clear it with
> `defaults delete com.gulsher.curlhit` when you are done with a sensitive request.

### Keyboard shortcuts

| Key | Action |
| --- | --- |
| `⌘↩` | Start |
| `⌘.` | Stop |

---

## Supported curl flags

Parsed and honoured:

`-X/--request` · `-H/--header` · `-d/--data/--data-raw/--data-ascii/--data-binary` ·
`--data-urlencode` · `--json` · `-F/--form/--form-string` · `-u/--user` · `-b/--cookie` ·
`-A/--user-agent` · `-e/--referer` · `-G/--get` · `-I/--head` · `-L/--location` ·
`-k/--insecure` · `-m/--max-time` · `--connect-timeout` · `--url`

Accepted and ignored, because they describe curl's own output rather than the request:
`-s`, `-v`, `-i`, `-o`, `-w`, `--compressed`, `--retry`, `--progress-bar` and friends.

Clustered (`-sk`) and glued (`-XPOST`) short flags work, as does the `--header=value`
form. Anything unrecognised is skipped and reported in the status bar rather than
failing the run.

Where curl and `URLSession` disagree, curl wins: **redirects are not followed** unless
you pass `-L`, and **a bad TLS certificate fails** unless you pass `-k`.

Two genuine limits:

- `-F name=@file` cannot read arbitrary paths from inside the sandbox. You get a warning rather than a silently empty upload.
- Response bodies are truncated in the viewer at 200,000 characters.

---

## How it works

```
Sources/CurlHit/
  CurlHitApp.swift     App entry point
  ContentView.swift    The whole UI
  Runner.swift         Stage/wave run loop, stats, verdict, clipboard export
  HTTPEngine.swift     URLSession wrapper with curl-compatible redirect and TLS behaviour
  CurlParser.swift     Shell tokeniser + curl flags → URLRequest
  Mutation.swift       Field extraction and the per-request randomisation strategies
Tools/make-icon.swift  Draws the app icon; no binary artwork in the repo
```

Fixed and Ramp are not two code paths. Both compile down to the same list of
`(parallel level, request count)` stages — Fixed is simply a single-stage plan — so
waves, intervals, cancellation and stop-on-failure have one implementation and cannot
drift apart between modes.

The engine is pure `URLSession`. It deliberately does **not** shell out to
`/usr/bin/curl`: a sandboxed app can't spawn binaries outside its bundle, so a
subprocess design could never have shipped on the App Store.

### Building with Xcode

```bash
open CurlHit.xcodeproj
```

Builds the same sources, with the icon compiled from `Resources/Assets.xcassets`. See
[`docs/APP_STORE.md`](docs/APP_STORE.md) for signing and submission.

---

## Using it responsibly

This app sends real requests to real servers. Point it at endpoints you own or are
authorised to test, and respect the target's terms of service and rate limits.

Defaults are intentionally gentle — one request at a time, a second apart — and
parallelism is capped at 50 on purpose. This is a tool for probing your own API's
limits, not for generating traffic against someone else's.

Worth being clear about what the numbers are: this measures one endpoint from one
machine over one network connection. It is a rate-limit prober and a smoke test, not a
distributed load generator. Past a few dozen parallel requests you are usually measuring
your own uplink rather than the server.

The bundled example uses [The Simpsons API](https://thesimpsonsapi.com) (credited on its
site to FacuG03), which is open, unauthenticated, CDN-served and publishes no rate
limit. Its data comes from [The Simpsons Wiki](https://simpsons.fandom.com) under
[CC BY-SA](https://creativecommons.org/licenses/by-sa/4.0/). It is referenced only as a
default URL — no Simpsons data is redistributed in this repo.

---

## License

MIT — see [LICENSE](LICENSE).
