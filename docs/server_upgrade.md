# Server Upgrade Plan

Review of `src/gen/serve.zig` (267 lines) against Trunk (`trunk-rs`) and
general WASM dev-server expectations. Captures what we have, what we lack,
and an ordered plan to close the gaps.

---

## Current State

### What We Have

| Capability                   | Implementation                                |
|------------------------------|-----------------------------------------------|
| Static file serving          | `root_dir.readFileAlloc`, 50 MB cap           |
| MIME types                   | `.html`, `.js`, `.wasm`, `.css`, `.json`, `.png`, `.wgsl`, `.svg`, `.ico`, `.woff2`, `.mp3`, `.ogg`, `.wav` |
| WebSocket live reload        | `/__zunk_ws` endpoint, `webzocket` library    |
| File-change detection        | Polling `dist/` mtime every 500ms             |
| Source watching + auto-rebuild | Polls `src/`, `build.zig`, runs configurable build cmd |
| SPA fallback                 | Extensionless 404 paths serve `index.html`    |
| Gzip compression             | Auto-compress >1KB compressible responses     |
| Single-target proxy          | `--proxy /prefix=http://host:port` TCP relay  |
| Browser error overlay        | Build errors shown via WS as red overlay      |
| Path traversal protection    | `..` substring check                          |
| Cache-Control: no-store      | Hardcoded on every response                   |
| COOP/COEP headers            | Hardcoded on every response (ahead of Trunk)  |
| Port-in-use error            | Explicit message on `AddressInUse`            |
| Windows support              | `socketRead`/`socketWrite` use `ws2_32`       |
| Thread-per-connection model  | `std.Thread.spawn` + detach                   |
| WebSocket client registry    | Fixed 16-slot array with mutex                |

### Architecture Diagram (Current)

```
                    +-----------+
                    |  Browser  |
                    +-----+-----+
                          |
        HTTP GET /        |       WS /__zunk_ws
        +-----------------+-----------------+
        |                                   |
  +-----v------+                   +--------v-------+
  | HTTP handler|                  | WS handshake   |
  | proxy check |                  | wsReadLoop     |
  | parsePath   |                  +--------+-------+
  | gzip check  |                           |
  | mimeType    |                  +--------v-------+
  | sendResponse|                  | WsRegistry     |
  +-----+------+                  | broadcast()    |
        |                         +---+--------+---+
  +-----v------+                      |        |
  | root_dir   |           +----------v--+ +---v-----------------+
  | (dist/)    |           | watcherThread| | sourceWatcherThread |
  +------------+           | polls dist/  | | polls src/          |
                           | sends reload | | runs zig build      |
  +------------+           +-------------+  | sends error/clear   |
  | proxyReq   |                            +---------+-----------+
  | TCP relay  |                                      |
  +------------+                              +-------v-------+
                                              | runBuild      |
                                              | Child process |
                                              | captures stderr|
                                              +---------------+
```

### Comparison with Trunk (`trunk-rs` v0.21.14)

| Feature                  | zunk                | Trunk                         |
|--------------------------|---------------------|-------------------------------|
| Live reload mechanism    | WS full page reload | WS full page reload           |
| Hot module replacement   | No                  | No                            |
| Watch target             | src/ + dist/        | Source dirs (configurable)     |
| Watch mechanism          | Polling (500ms)     | `notify` crate (inotify etc.) |
| Auto-rebuild on change   | Yes (configurable)  | Yes (full cargo rebuild)       |
| Debounce                 | 100ms               | 25ms debounce + 1s cooldown   |
| Cache-Control headers    | no-store            | None                          |
| COOP/COEP headers        | Always on           | Manual config required        |
| SPA fallback             | Yes (extensionless) | Default on                    |
| Gzip/Brotli              | Gzip (auto)         | No (open issue)               |
| Proxy support            | Single-target       | HTTP + WS proxy, multi-target |
| HTTPS/TLS                | No                  | rustls or OpenSSL             |
| Browser error overlay    | Yes (WS + overlay)  | Build errors via WS           |
| Custom headers           | Hardcoded           | Arbitrary via Trunk.toml      |
| WASM MIME type            | Correct             | Correct                       |
| Source maps              | No                  | No (proposal open)            |
| `.wgsl` MIME type        | Yes                 | N/A (not Zig-focused)         |
| Address/port config      | Hardcoded 127.0.0.1 | CLI, env, Trunk.toml          |
| File hashing             | Done at build time  | Default on                    |

### Identified Gaps (Ordered by Impact)

**Critical for "save and see" loop:**
1. No source watching -- only watches `dist/`, does not trigger rebuilds
2. No `Cache-Control` header -- browsers may serve stale `.wasm`/`.js` from cache
3. No `.wgsl` MIME type -- WebGPU shader files served as `application/octet-stream`

**Quality of life:**
4. No SPA fallback -- client-side routing gets 404s
5. No compression -- large `.wasm` files transferred uncompressed
6. No proxy -- API backends require CORS workarounds during dev

**Polish:**
7. No error overlay -- build failures only visible in terminal, not browser

---

## TODOs

### Must-have for usable dev experience

- [x] **[1] Source watching + auto-rebuild** -- sourceWatcherThread polls
  src/ and build.zig for mtime changes, runs configurable build command
  via std.process.Child, captures stderr for error overlay. 100ms debounce.

- [x] **[2] Cache-Control: no-store header** -- already implemented in serve.zig.

- [x] **[3] .wgsl MIME type** -- added .wgsl, .svg, .ico, .woff2, .mp3, .ogg, .wav.

### Nice-to-have for good dev experience

- [x] **[4] SPA fallback to index.html** -- extensionless paths that 404
  now serve index.html instead, enabling client-side routing.

- [x] **[5] Gzip compression** -- responses >1KB with compressible MIME types
  are gzip-compressed when the client sends Accept-Encoding: gzip. Uses
  std.compress.flate with gzip container, heap-allocated compressor.

- [x] **[6] Single-target proxy (--proxy)** -- `--proxy /api=http://localhost:3000`
  forwards matching requests to a backend via TCP relay. Rewrites the
  request line and relays the full response.

### Polish

- [x] **[7] Browser error overlay via WebSocket** -- build failures send
  "error:<stderr>" over WS, displayed as a full-screen red overlay.
  Successful builds send "clear" to dismiss. wsWriteText now supports
  messages >125 bytes via extended length frames.

---

## Implementation Notes

### [1] Source Watching + Auto-Rebuild (the big one)

Current watcher (`watcherThread`) polls `dist/` every 500ms by summing
mtimes. To support source watching + auto-rebuild:

```
Source watcher (new)          Build            Dist watcher (existing)
        |                      |                       |
  detect src change -----> run zig build -----> detect dist change
                                                       |
                                                 WS broadcast "reload"
                                                       |
                                                 browser refreshes
```

Key decisions:
- Keep polling (simpler, cross-platform) or switch to `notify`-style?
  Polling is fine for now -- 500ms is fast enough for dev.
- Watch paths: project root `src/`, `build.zig`, `build.zig.zon`
- Debounce: accumulate changes for ~100ms before triggering build
- Cooldown: skip source-change checks while a build is in progress
- Build invocation: `zig build` via `std.process.Child`
- Error capture: read stderr, forward to WS clients if [7] is implemented

### [2] Cache-Control Header

Single line addition to `sendResponse`:

```zig
"Cache-Control: no-store\r\n" ++
```

### [3] .wgsl MIME Type

Single line addition to `mimeType`:

```zig
if (std.mem.eql(u8, ext, ".wgsl")) return "text/wgsl";
```

Also consider adding while we are there:
- `.svg` -> `image/svg+xml`
- `.ico` -> `image/x-icon`
- `.woff2` -> `font/woff2`

### [4] SPA Fallback

In `handleHttpRequest`, when file open fails:

```zig
// If path has no extension, try index.html (SPA fallback)
if (std.fs.path.extension(rel_path).len == 0) {
    // serve index.html instead
}
```

### [5] Gzip Compression

Zig stdlib has `std.compress.gzip`. Check `Accept-Encoding` header,
compress if body > 1KB, add `Content-Encoding: gzip` to response.
Only compress text-like types (html, js, css, json, wgsl), not
already-compressed formats (png, wasm is debatable but compresses well).

### [6] Proxy

Parse `--proxy http://localhost:8000/api` from CLI args. In
`handleHttpRequest`, if path starts with `/api`, open a TCP connection
to the backend, forward the request, relay the response. Keep it simple --
no connection pooling, no WebSocket proxy (initially).

### [7] Error Overlay

Extend the WS protocol:
- `"reload"` -> browser refreshes (existing)
- `"error:<message>"` -> browser shows overlay (new)
- `"clear"` -> browser dismisses overlay (new)

The client-side script (injected into index.html by the generator) would
need a small addition to parse these messages and manage a DOM overlay.

---

## Priority Order

The implementation order follows a dependency chain:

```
[2] Cache-Control  ----+
[3] .wgsl MIME     ----+--> trivial, do first
                        |
[1] Source watching ----+--> biggest impact, do next
                        |
[4] SPA fallback   ----+--> independent, slot in anytime
                        |
[7] Error overlay  ----+--> depends on [1] (needs build error capture)
                        |
[5] Gzip           ----+--> independent, lower priority
[6] Proxy          ----+--> independent, lowest priority
```

Suggested commit sequence:
1. `[2] + [3]` together (one small commit)
2. `[1]` source watching (larger, own commit)
3. `[4]` SPA fallback (own commit)
4. `[7]` error overlay (own commit, builds on [1])
5. `[5]` gzip (own commit)
6. `[6]` proxy (own commit)
