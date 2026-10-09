# Curl Hit

A tiny native macOS app that replays a `curl` command N times at a fixed interval and shows you every response.

Paste a curl (or just a URL), set **count** and **interval**, press Start. That's it.

- **Native and small** — SwiftUI + AppKit only. ~1.7 MB app, no frameworks bundled, no Electron, no runtime deps.
- **Local only** — no database, no accounts, no telemetry, nothing written to disk except your last-used inputs in `UserDefaults`.
- **Sandboxed** — ships with the App Sandbox on and exactly one entitlement: outgoing network.
- **Real curl parsing** — headers, methods, bodies, basic auth, cookies, multi-line `\` pastes.

## Install

```bash
git clone https://github.com/<you>/curl-hit.git
cd curl-hit
./build.sh
open build/CurlHit.app
```

`build.sh` needs only the Swift compiler that ships with Xcode or the Command Line Tools — no Xcode project, no SPM fetch. To keep the app around:

```bash
cp -R build/CurlHit.app /Applications/
```

## Using it

| Field | Meaning |
| --- | --- |
| Request | A full curl command, or a bare URL (`https://` is assumed if you omit the scheme) |
| Count | How many times to send it, 1–100000 |
| Mode | **Fixed** sends one batch at a chosen parallelism; **Ramp** steps through levels to find the limit |
| Parallel | Fixed mode: how many go out **at once**, 1–50. `1` is one-at-a-time |
| Parallel levels | Ramp mode: the ladder to climb, e.g. `1, 2, 5, 10, 20` (max 12 rungs, each capped at 50) |
| Per level | Ramp mode: how many requests to send at each rung |
| Interval | Delay *between* hits, in ms or seconds. `0` fires back-to-back |
| Timeout (s) | Per-request timeout; `-m` in the pasted curl wins over this |
| Stop on failure | Halt the run on the first non-2xx/3xx response |

Shortcuts: `⌘↩` start, `⌘.` stop.

### Ramp mode — finding the limit

Guessing a parallelism number and re-running by hand is slow. Ramp mode climbs a ladder
instead: it runs `Per level` requests at each level in `Parallel levels`, then tells you
in one line what it found.

```
stage  sent   ok   429   p95      req/s
x1     16     16   0     166ms    6.4
x4     16     16   0     158ms    25.4
x8     16     16   0     160ms    50.1
x16    16     8    8     165ms    96.9

Rate limited at 16 parallel — 8/16 got 429.
```

The **Stages** tab shows that table; the verdict appears above it. It distinguishes the
cases that matter:

- **429s appear** → a real quota, and it names the level where it starts
- **5xx or dropped connections appear** → the server is breaking rather than throttling
- **No errors but p95 bends past 2x baseline** → queuing, not a quota: you found the
  concurrency where it starts falling behind, not a configured limit
- **Nothing bends** → no limit up to the top rung, with the peak throughput reached

### Load and rate-limit testing

Set **Parallel** above 1 and requests go out in waves: `Parallel` of them fire together,
the wave is awaited, then **Interval** applies before the next wave. So `Count 100`,
`Parallel 10`, `Interval 0` is ten waves of ten, back to back.

The readout is built for exactly this:

- **Req/s** — completed requests per second of wall clock, the number that should climb as you raise Parallel
- **p95** — 95th-percentile latency, which exposes throttling and queuing long before the average does
- **Status breakdown** — a chip per status code (`200 x85  429 x15`), with **429 shown in purple** since that is the one you are usually hunting
- **Rate-limit headers** — if the server sends `Retry-After`, `X-RateLimit-*` or RFC-style `RateLimit-*`, the latest values appear under the progress bar

A note on what the numbers mean: this measures your endpoint from one machine over one
network. It is a rate-limit prober and a smoke test, not a distributed load generator —
past a few dozen parallel requests you are usually measuring your own uplink rather than
the server.

The app opens on a harmless example — 5 requests, a second apart, against
[The Simpsons API](https://thesimpsonsapi.com), a public endpoint that needs no key:

```
https://thesimpsonsapi.com/api/characters
```

Replace it with your own curl. A full one works as-is:

```bash
curl -X POST 'https://example.com/api/login' \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer <token>' \
  --data-raw '{"email":"you@example.com","password":"secret"}'
```

Each hit is listed with its status code, duration and wall-clock time. Select one to read its body (JSON is pretty-printed) and response headers. **Copy CSV** puts the whole run on the clipboard as `hit,status,ms,bytes,started_at,error`.

By default requests run one at a time; raise **Parallel** to overlap them.

## Supported curl flags

Parsed and honoured:

`-X/--request` · `-H/--header` · `-d/--data/--data-raw/--data-ascii/--data-binary` · `--data-urlencode` · `--json` · `-F/--form/--form-string` · `-u/--user` · `-b/--cookie` · `-A/--user-agent` · `-e/--referer` · `-G/--get` · `-I/--head` · `-L/--location` · `-k/--insecure` · `-m/--max-time` · `--connect-timeout` · `--url`

Accepted and ignored, because they only describe curl's own output: `-s`, `-v`, `-i`, `-o`, `-w`, `--compressed`, `--retry`, `--progress-bar` and friends. Clustered (`-sk`) and glued (`-XPOST`) short flags work. Anything unrecognised is skipped and reported in the status bar rather than failing the run.

Behaviour matches curl where the two differ from `URLSession` defaults: redirects are **not** followed unless you pass `-L`, and a bad TLS certificate fails unless you pass `-k`.

Two limits worth knowing:

- `-F name=@file` can't read arbitrary paths from inside the sandbox, so file uploads are reported as a warning instead of silently sending nothing.
- Response bodies are truncated in the viewer at 200,000 characters.

## How it works

```
Sources/CurlHit/
  CurlHitApp.swift    App entry point
  ContentView.swift   The whole UI
  Runner.swift        Run loop, counters, clipboard export
  HTTPEngine.swift    URLSession wrapper (curl-compatible redirect/TLS behaviour)
  CurlParser.swift    Shell tokeniser + curl flags → URLRequest
Tools/make-icon.swift Draws the app icon; no binary artwork in the repo
```

The engine is pure `URLSession` and deliberately **does not** shell out to `/usr/bin/curl`: a sandboxed app can't spawn binaries outside its bundle, so a subprocess design could never ship on the App Store.

## Building with Xcode

```bash
open CurlHit.xcodeproj
```

The project builds the same sources into `CurlHit.app`, with the icon compiled from `Resources/Assets.xcassets`. See [`docs/APP_STORE.md`](docs/APP_STORE.md) for the signing and submission steps.

## Requirements

macOS 13 Ventura or later. Apple silicon or Intel (`build.sh` targets your own architecture; the Xcode project builds universal).

## Using it responsibly

This app sends real requests to real servers, so the usual rules apply: point it at
endpoints you own or are authorised to test, and respect the target's terms of service
and rate limits. Defaults are intentionally conservative — one request at a time — and
parallelism is capped at 50, deliberately: this is a tool for probing your own API's
limits, not for generating traffic against someone else's.

The bundled example uses [The Simpsons API](https://thesimpsonsapi.com) (credited on its
site to FacuG03), which is open and unauthenticated and publishes no rate limit; its
responses are served from a CDN. Its data comes from
[The Simpsons Wiki](https://simpsons.fandom.com) under
[CC BY-SA](https://creativecommons.org/licenses/by-sa/4.0/). It's referenced here only
as a default URL — no Simpsons data is redistributed in this repo.

## License

MIT — see [LICENSE](LICENSE).
