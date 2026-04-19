# Plan: bridge.js convention + source maps + HMR

Scratchpad for three roadmap items. Implement in order, land each as its own PR.
Source of truth for scope when context is lost. If you diverge from this doc,
update it first.

---

## 4.3 -- bridge.js package convention (FIRST)

### Problem

Today only the user project's root `bridge.js` (or `js/bridge.js`) is picked up.
A library like teak wants to ship its own JS without every consumer pasting it
in. Filesystem scans of the Zig package cache are unsafe (can't tell what the
user actually depends on). The Zig build system is the only authority on the
dep graph, so the handoff must go through `build.zig`.

### Design

**User-side:** `zunk.installApp` gains a `bridge_deps: []const *std.Build.Dependency`
field. The user lists deps that ship a `bridge.js`:

```zig
const zunk = b.dependency("zunk", .{});
const teak = b.dependency("teak", .{});
zunk.installApp(b, exe, .{ .bridge_deps = &.{ teak } });
```

**installApp:** for each dep, emits `--bridge-dep <lazy path>` using
`gen_cmd.addFileArg(dep.path("bridge.js"))`. Zig's build system resolves lazy
paths to real filesystem paths at run time, and fails loudly if the file is
missing -- that is the correct behavior (a dep declared as bridge-carrying
must actually carry one).

**CLI:** `--bridge-dep <path>` is repeatable. Collected into a list. Still
accept the existing project-root auto-discovery (`bridge.js`, `js/bridge.js`)
for the user's own bridge.js.

**Merge order in generated JS:**
1. Dep bridges, in the order listed in `bridge_deps` (library layer first)
2. User project's own bridge.js last (so user can override dep symbols)

Each chunk is prefixed with a banner comment naming its origin:
`// --- bridge.js from <origin-label> ---`. Origin label = file path for
user, basename of dep package dir for deps (e.g. `teak`).

**Types in js_gen:** `GenOptions.bridge_js: ?[]const u8` becomes
`bridge_js_chunks: []const BridgeJsChunk` where
`BridgeJsChunk = struct { origin: []const u8, source: []const u8 }`.
Empty slice = no bridges. `generate` concatenates with banners.

**Build cache fingerprint:** include mtimes of every `--bridge-dep` path, not
just the user's bridge.js.

**Docs:** add a section to README ("Shipping a bridge.js in a zunk library")
explaining the filename convention (`bridge.js` at dep package root), how to
wire it via `bridge_deps`, and the merge order / override precedence.

### Out of scope for this PR

- Auto-discovery by scanning the cache -- rejected (unsafe).
- Multiple bridge files per dep.
- Naming conflicts between deps (last write wins -- document, don't police).

---

## 4.4 -- source maps (SHIPPED in v0.4.0, bridge-section scope)

Landed scope is narrower than what follows: v1 emits Source Map v3 with one
source per bridge.js chunk only. No category-level sections, no DWARF. The
teak-specific win (stack traces from library-provided bridge.js land in
readable library code) is met. Category-level sectioning moves to a follow-up.

### Scope: name-section only, not DWARF

The big win for teak developers is seeing real Zig function names in devtools
stack traces instead of `wasm-function[1234]`. Chrome/Firefox already render
WASM function names from the `name` custom section, so the generated JS
doesn't strictly need a .js.map for *that*. What a .js.map gets us:

- Mapping generated JS lines back to something meaningful when a JS-side
  trampoline throws (it currently shows a line in `app-<hash>.js` with no
  clue whether it's in a canvas wrapper or an audio wrapper).

### Plan

1. Track `{generated_line -> (source_tag, original_line)}` tuples while
   writing the JS. `source_tag` = category string (`"canvas"`, `"audio"`,
   `"webgpu"`, `"bridge:teak"`, `"runtime"`, etc.). Start coarse -- line per
   emitted extern wrapper is enough.
2. Emit a VLQ-encoded .js.map (Source Map v3) alongside `app-<hash>.js`.
   Sources list is synthetic (`zunk://canvas.js`, `zunk://audio.js`, etc.),
   each file contents = the concatenated lines tagged to that category, so
   devtools has something to display when clicking through.
3. Reference it via `//# sourceMappingURL=app-<hash>.js.map` at the tail of
   the generated JS. In `deploy`, the map file gets its own content-hashed
   filename.
4. Serve `.js.map` with `application/json` MIME in `serve.zig`.

### Out of scope

- DWARF -> Zig source line numbers. Bigger project (parse WASM DWARF
  sections, build line tables). Deferred. Mention in doc.
- Mapping back to Zig for the *WASM* side -- browsers already handle this if
  the WASM binary has a `name` section and DWARF sections (Zig leaves these
  in by default except at ReleaseSmall).

---

## 5.1 -- HMR (SHIPPED in v0.5.0, opt-in)

Landed as `zunk run --hmr`. Generated JS exposes `__zunkHmrSwap(wasmUrl)`;
the dev server sends `hmr:<url>` when only `.wasm` changed in `dist/`.
Optional Zig exports `__zunk_hmr_serialize` / `__zunk_hmr_hydrate`
preserve app state through the existing 64 KB exchange buffer. Any
failure in the swap falls back to `location.reload()`. Full protocol is
in `docs/hmr.md`. Follow-ups: the `zunk.bind.exposeHmr` helper, and
flipping `--hmr` on by default once teak reports back.

### Design sketch (MUST WRITE A `docs/hmr.md` BEFORE CODING)

**Trigger:** existing WebSocket (`/__zunk_ws`) already broadcasts a `"reload"`
message today. Add a `"hmr"` message type sent when only the WASM binary
changed (JS scaffolding unchanged). If JS or HTML changed, fall back to full
reload.

**Runtime protocol (JS side):**
1. Fetch new `.wasm` into an ArrayBuffer.
2. Instantiate with the *same* imports object -- handle table, audio context,
   WebGPU device, WebSocket connections all preserved.
3. If old module exports `cleanup`, call it.
4. If old module exports `serialize_model` and new module exports
   `hydrate_model`, call `serialize_model()` on old (returns ptr+len into old
   memory), copy bytes out into a JS Uint8Array, drop old memory, call
   `hydrate_model(ptr, len)` on new module (after copying bytes into new
   memory via shared exchange buffer).
5. Else call `init` on new module.
6. Resume the rAF loop against the new `frame` export.

**Runtime protocol (Zig side, opt-in for teak):**
- Teak adds `export fn serialize_model() [*]u8` / returns a length via a
  paired export, OR writes into an agreed-upon exchange slot. Design this
  more concretely in `docs/hmr.md`. Ideal ergonomics: `zunk.bind.exposeHmr`
  helper that takes a `*Model` and a `SerializeFn`.

**Constraints / gotchas:**
- Old WASM memory holds the old Model, pointers into old memory are
  invalidated after swap. serialize_model must produce a self-contained byte
  blob (no pointers).
- Callbacks registered on the old module (e.g. `requestAnimationFrame`
  chained, audio buffer end) must be redirected to new module's exports.
  Handle table entries keyed by function index need re-resolution: store
  *export names* alongside indices so we can re-lookup after swap.
- Bridge.js functions that closed over old `instance` references must take
  the instance from a mutable module-level variable, not a closure capture.
  Generated JS will need refactor: replace per-call closures with
  `currentInstance` lookups.

**Fallback:** if anything goes wrong (hydrate_model missing, memory corrupt,
export signature changed), log to browser console and do a full reload. HMR
is a DX nicety, never required for correctness.

**Flag:** `--hmr` on `zunk run` (default off during stabilization, flip on by
default once teak validates it).

### Phases

1. Write `docs/hmr.md` with full protocol before any code.
2. Refactor generated JS to use module-level `currentInstance` instead of
   closure capture.
3. Add `"hmr"` WebSocket message + client handler (full reload fallback
   baked in from day 1).
4. Add Zig-side `zunk.bind.exposeHmr` helper + example wiring in the
   imgui-demo example.
5. Teak integrates and reports back.

---

## Cross-cutting conventions

- Each PR has its own branch off master: `feat/bridge-deps`, `feat/sourcemaps`,
  `feat/hmr`.
- Version bump in `build.zig.zon` per PR (CI enforces this on master).
- Examples must still build after each PR. particle-life + imgui-demo are
  the canaries.
- No deletions -- archive per CLAUDE.md rule 1.
