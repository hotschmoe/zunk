# HMR (Hot Module Replacement)

Draft protocol for roadmap item 5.1. This doc is the spec; if you diverge
during implementation, update this first.

---

## Goal

When a user edits Zig code, the watcher rebuilds the `.wasm`. If *only* the
`.wasm` changed (JS scaffolding, HTML, and bridges are identical), swap the
WASM module in place instead of reloading the page. JS-side state that is
expensive to recreate -- handle table, WebGPU device & pipelines, audio
context, WebSocket connections, pointer-lock grab, microphone permission --
survives the swap.

Zig-side state (everything in WASM linear memory, including any app Model)
is lost by default. An optional serialize/hydrate hook preserves it for apps
that opt in (teak's TEA `Model` is the canonical case).

Fallback at every layer: if anything is wrong, do a full `location.reload()`.
HMR is a DX nicety, never required for correctness.

---

## Trigger conditions

The dev server issues `"hmr:<wasm_url>"` instead of `"reload"` iff:

1. The `.wasm` file in `dist/` changed, AND
2. No other file in `dist/` changed in the same rebuild (same JS, same
   HTML, same `.js.map`, same assets).

If any file other than `.wasm` changed, the existing `"reload"` path fires
unchanged. This is a coarse heuristic but handles the 95% case: editing
`src/main.zig` typically only changes the `.wasm`; adding a new extern fn
or changing an import signature regenerates the JS and forces a full reload.

Implementation: split `dist/` fingerprinting into two buckets -- wasm files
vs. everything else. Compare both per poll cycle.

---

## Wire protocol

WebSocket endpoint: unchanged (`/__zunk_ws`).

Messages (server -> client):

| Message          | Meaning                                           |
|------------------|---------------------------------------------------|
| `reload`         | Full page reload (existing behavior).             |
| `hmr:<wasm_url>` | Hot-swap the WASM module. `<wasm_url>` is the    |
|                  | path the browser should fetch (e.g. `/app.wasm`). |
| `clear`          | Clear build error overlay (existing).             |
| `error:<text>`   | Show build error overlay (existing).              |

Client behavior on `hmr:<url>`:
1. Try `window.__zunkHmrSwap(url)`.
2. If it resolves: success. No reload.
3. If it rejects (or is undefined): `location.reload()`.

---

## Client-side swap sequence (`__zunkHmrSwap`)

Generated into `app.js`. Exposed on `window` so the reload script can call
it. Pseudocode:

```
async function __zunkHmrSwap(wasmUrl) {
  try {
    // 1. Cancel the render loop so old `exports.frame` can't run during swap.
    if (zunkFrameId) cancelAnimationFrame(zunkFrameId);
    zunkFrameId = 0;

    // 2. Ask the old module to cleanup (cancel pending timers, release
    //    OS-ish resources that are NOT handle-table entries).
    if (exports && exports.cleanup) exports.cleanup();

    // 3. Optional: snapshot the old Model for hydrate.
    let snapshot = null;
    if (exports && exports.__zunk_hmr_serialize) {
      const len = exports.__zunk_hmr_serialize();  // writes into exchange buf
      if (len > 0) {
        const ptr = exports.__zunk_string_buf_ptr.value;
        snapshot = new Uint8Array(memory.buffer, ptr, len).slice();  // copy out
      }
    }

    // 4. Load and instantiate the new WASM with the SAME env import object.
    //    env methods close over mutable bindings (`exports`, `memory`, `H`,
    //    `readStr`), so they transparently switch targets.
    const response = await fetch(wasmUrl);
    const { instance: newInstance } = await WebAssembly.instantiateStreaming(response, { env });

    // 5. Rebind module-level mutable state.
    instance = newInstance;
    exports = instance.exports;
    memory = exports.memory;
    if (H) { H._exports = exports; H._memory = memory; }
    readStr = (ptr, len) => new TextDecoder().decode(new Uint8Array(memory.buffer, ptr, len));
    // WebGPU state (device, context, pipelines) survives: it lives in H.

    // 6. Initialize the new module.
    if (snapshot && exports.__zunk_hmr_hydrate) {
      // Copy snapshot into new module's exchange buffer, then call hydrate.
      const ptr = exports.__zunk_string_buf_ptr.value;
      new Uint8Array(memory.buffer, ptr, snapshot.length).set(snapshot);
      exports.__zunk_hmr_hydrate(ptr, snapshot.length);
    } else if (exports.init) {
      exports.init();  // Fresh start.
    }

    // 7. Resume the render loop against the NEW `exports.frame`.
    if (exports.frame) {
      zunkLastTime = performance.now();
      zunkFrameId = requestAnimationFrame(zunkFrame);
    }
  } catch (err) {
    console.error('[zunk hmr] swap failed, falling back to full reload:', err);
    location.reload();
  }
}
window.__zunkHmrSwap = __zunkHmrSwap;
```

---

## Generated-JS refactor required

The current generator emits:

```js
const { instance } = await WebAssembly.instantiateStreaming(...);
const exports = instance.exports;
const memory = exports.memory;
```

These `const` bindings are closure-captured by the env object's methods,
`zunkFrame`, `zunkResize`, input handlers, etc. They are immutable -- no
way to swap.

Change to:

```js
let instance, exports, memory;
let readStr = () => '';            // also let, not const
// env object is defined BEFORE instantiation and closes over the outer
// `let` bindings. env methods resolve `exports`, `memory`, `H`, `readStr`
// at call time, so they automatically target whichever module is live.
const env = { ... };

async function __zunkLoad(wasmUrl) {
  const response = await fetch(wasmUrl);
  const { instance: inst } = await WebAssembly.instantiateStreaming(response, { env });
  instance = inst;
  exports = instance.exports;
  memory = exports.memory;
  if (H) { H._exports = exports; H._memory = memory; }
  readStr = (ptr, len) => new TextDecoder().decode(new Uint8Array(memory.buffer, ptr, len));
}

await __zunkLoad('app.wasm');
if (exports.init) exports.init();
```

The render loop, resize handler, etc. stay as they are -- they reference
`exports.frame`, which at call time resolves the live `let exports`.

**One subtlety:** any bridge.js function that captures `instance` or
`exports` via a closure BEFORE WASM load will hold a stale reference after
swap. The convention has always been that bridge.js defines helpers used BY
the env object (which closes over mutable bindings), so in practice this is
fine -- but document it as a bridge.js rule: "do not close over `exports`
or `instance`; access them through the live module-level binding at call
time."

---

## Zig-side API (optional, opt-in for state preservation)

Two exports. If either is missing, HMR still works but Zig state resets.

```zig
/// Serialize app state into the exchange buffer. Returns byte length.
/// Return 0 to indicate "no state to preserve, just run init on the new
/// module".
export fn __zunk_hmr_serialize() u32 { ... }

/// Hydrate app state from the exchange buffer. `ptr` points into WASM
/// linear memory and `len` is the byte count.
export fn __zunk_hmr_hydrate(ptr: [*]const u8, len: u32) void { ... }
```

The exchange buffer is the existing `bind.__zunk_string_buf` (64 KB,
already exposed for string marshaling). Apps with larger state should
either (a) compress, or (b) extend this to a dedicated larger buffer
(follow-up).

Convention: the serialized format must be pointer-free (no absolute
addresses into old memory), since the new WASM instance has a completely
separate linear memory. Use POD layouts, offsets from a base, or explicit
(de)serialization. For teak's Model this is natural -- TEA's Model is
already a plain struct by design.

**Out of scope for v1**: a `zunk.bind.exposeHmr(comptime T, *T, ...)`
helper that generates these exports from a pair of user-provided
serialize/hydrate functions. Land the raw exports first; teak can prove the
ergonomics, then we add the helper.

---

## `--hmr` flag

Opt-in on `zunk run`:

```
zunk run --hmr
```

When enabled, the dev server:
- Watches `dist/` with wasm-vs-rest split fingerprinting
- Emits `hmr:<url>` instead of `reload` for wasm-only changes

When disabled (default), behavior is unchanged from today: every `dist/`
change triggers `reload`.

The generated JS always contains `__zunkHmrSwap`; whether it's called is a
server-side decision. This keeps the JS output deterministic regardless of
dev-server flags.

Flag flips to default-on once teak has validated the protocol end-to-end.

---

## What's NOT in v1

- The `zunk.bind.exposeHmr` ergonomic helper (manual exports only).
- Callback-table rehydration: WASM-side callbacks registered via
  `bind.registerCallback` store function indices that are invalidated by
  swap. Apps using persistent JS-registered callbacks (e.g. the audio
  callback) will need to re-register in `init` / `__zunk_hmr_hydrate`.
  Document this, don't automate it yet.
- Preserving in-flight `fetch` / `ws` messages across swap. They complete
  against the new module or are dropped; app code handles idempotency.
- HMR of bridge.js edits. Any bridge.js change forces a full reload (it's
  part of the JS bundle, so by trigger-condition logic it already does).

---

## Implementation plan (v1)

1. **This doc** (done).
2. Refactor `gen/js_gen.zig` to emit mutable `instance/exports/memory/readStr`
   and the `__zunkLoad` + `__zunkHmrSwap` helpers. Keep all existing behavior
   identical for non-HMR use.
3. Update the reload script in `gen/serve.zig` to handle `hmr:<url>`
   messages -- call `window.__zunkHmrSwap(url)`, fall back to reload on
   rejection.
4. Split `watcherThread` in `gen/serve.zig` into wasm-vs-rest fingerprints,
   emit `hmr:<url>` or `reload` accordingly. Gated on a new
   `ServeConfig.hmr` bool.
5. Plumb `--hmr` through `main.zig`.
6. Smoke-test: edit `examples/input-demo/src/main.zig`, confirm swap
   completes without a full reload. Verify the input handlers still work
   (this tests that env methods correctly resolve the new `exports` at
   call time).
7. Version bump.

Non-goals for v1: the Zig-side serialize/hydrate hooks are *supported* by
the protocol but no example uses them yet. Teak integration will exercise
them and inform the eventual `exposeHmr` helper shape.
