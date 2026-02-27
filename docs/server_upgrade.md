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
| MIME types                   | `.html`, `.js`, `.wasm`, `.css`, `.json`, `.png` |
| WebSocket live reload        | `/__zunk_ws` endpoint, `webzocket` library    |
| File-change detection        | Polling `dist/` mtime every 500ms             |
| Path traversal protection    | `..` substring check                          |
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
  | parsePath   |                  | wsReadLoop     |
  | mimeType    |                  +--------+-------+
  | sendResponse|                           |
  +-----+------+                   +--------v-------+
        |                          | WsRegistry     |
  +-----v------+                   | broadcast()    |
  | root_dir   |                   +--------+-------+
  | (dist/)    |                            |
  +------------+              +-------------v-----------+
                              | watcherThread           |
                              | pollDirChanged (500ms)  |
                              | watches dist/ only      |
                              +-------------------------+
```

### Comparison with Trunk (`trunk-rs` v0.21.14)

| Feature                  | zunk                | Trunk                         |
|--------------------------|---------------------|-------------------------------|
| Live reload mechanism    | WS full page reload | WS full page reload           |
| Hot module replacement   | No                  | No                            |
| Watch target             | dist/ only          | Source dirs (configurable)     |
| Watch mechanism          | Polling (500ms)     | `notify` crate (inotify etc.) |
| Auto-rebuild on change   | No                  | Yes (full cargo rebuild)       |
| Debounce                 | N/A                 | 25ms debounce + 1s cooldown   |
| Cache-Control headers    | None                | None                          |
| COOP/COEP headers        | Always on           | Manual config required        |
| SPA fallback             | No (404)            | Default on                    |
| Gzip/Brotli              | No                  | No (open issue)               |
| Proxy support            | No                  | HTTP + WS proxy, multi-target |
| HTTPS/TLS                | No                  | rustls or OpenSSL             |
| Browser error overlay    | No                  | Build errors via WS           |
| Custom headers           | Hardcoded           | Arbitrary via Trunk.toml      |
| WASM MIME type            | Correct             | Correct                       |
| Source maps              | No                  | No (proposal open)            |
| `.wgsl` MIME type        | Missing             | N/A (not Zig-focused)         |
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

- [ ] **[1] Source watching + auto-rebuild** -- the "save and see" loop.
  Watch source directories (not just `dist/`), trigger `zig build`
  on change, then broadcast reload. Consider 25ms debounce + cooldown
  to avoid rebuild storms. This is the single biggest dev experience gap.

- [ ] **[2] Cache-Control: no-store header** -- 30-second fix, prevents real pain.
  Add `Cache-Control: no-store\r\n` to `sendResponse` header template.
  Ensures browsers always fetch fresh content during development.

- [ ] **[3] .wgsl MIME type** -- 30-second fix, needed for WebGPU.
  Add `if (std.mem.eql(u8, ext, ".wgsl")) return "text/wgsl";` to `mimeType`.
  Without this, `fetch("shader.wgsl")` may fail or warn in some browsers.

### Nice-to-have for good dev experience

- [ ] **[4] SPA fallback to index.html** -- when a path resolves to 404,
  serve `index.html` instead (only for non-file paths, i.e. paths without
  a file extension). Enables client-side routing without server config.

- [ ] **[5] Gzip compression (opt-in)** -- compress responses above a size
  threshold when the client sends `Accept-Encoding: gzip`. Significant
  for `.wasm` files which compress ~60-70%. Can use `std.compress.gzip`
  from the standard library. Should be opt-in via CLI flag.

- [ ] **[6] Single-target proxy (--proxy)** -- forward requests matching a
  path prefix to a backend server. Eliminates CORS pain during dev.
  Single target is sufficient; no need for Trunk's multi-target system.

### Polish

- [ ] **[7] Browser error overlay via WebSocket** -- when a build fails,
  send the error text over the existing WS connection. Inject a small
  `<div>` overlay in the client-side reload script that displays build
  errors. Dismiss on next successful build. Trunk does this and users
  value it highly.

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
