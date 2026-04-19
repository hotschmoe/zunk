# Teak → Zunk follow-up items

Context: teak's `examples/counter_greeter` now builds + runs through
zunk (branch `dev-hotschmoe` @ `c8395f5`, zunk v0.2.0). These are the
rough edges surfaced during integration. All are minor; teak is working
around each locally. Ordered by priority.

**Status (2026-04-19, zunk v0.5.3)**: all seven items below are landed.
Teak can drop the workarounds noted under each section and pin
zunk >= 0.5.3.

| Item | Status | Landed in |
|------|--------|-----------|
| §1 `installApp` step-name collision | DONE | `4f1dbbe` (v0.5.1) |
| §2 HiDPI coordinate-space mismatch  | DONE | `510d970` (v0.5.2) |
| §3 `typed_chars` non-text leak      | DONE | `fd68ff5` (PR #9, pre-v0.5.1) |
| §4 Missing keys in `Key` enum       | DONE | `4f1dbbe` (v0.5.1) |
| §5 Mouse edge events                | DONE | `f12aabb` (v0.5.3) |
| §6 Canvas ownership/resize docs     | DONE | `f12aabb` (v0.5.3) |
| §7 Per-frame arena pattern          | DONE (docs only) | `f12aabb` (v0.5.3) |

**Companion doc**: [`zunk-roadmap.md`](zunk-roadmap.md) — the bigger
workstreams (sampler + texture primitives, text-to-texture helper).
That's where the "what do we build next?" conversation lives; this doc
is the smaller-ticket follow-up list.

## 1. `installApp` step-name collision — DONE (v0.5.1, `4f1dbbe`)

**Problem.** `zunk.build.installApp` unconditionally registers a build
step named `"run"`. A consumer whose top-level `build.zig` already owns
a `"run"` step (e.g. a non-web CLI variant) can't call `installApp`
directly — `b.step("run", ...)` errors on duplicate.

**Teak workaround.** `linkWebWgpu` in teak's root `build.zig` inlines a
copy of `installApp`'s body with the step renamed to `"web-run"` (and a
sibling `"web"` build-only step). Every time zunk's CLI arg surface
changes, teak has to chase it.

**Ask.** Extend `InstallAppOptions` so step names are caller-controlled:

```zig
pub const InstallAppOptions = struct {
    port: u16 = 8080,
    output_dir: []const u8 = "dist",
    run_step_name: []const u8 = "run",
    build_step_name: ?[]const u8 = null, // optional; if set, register a build-only step
};
```

Once shipped, teak's `linkWebWgpu` drops the fork and calls
`zunk.installApp(b, dep, exe, .{ .run_step_name = "web-run", .build_step_name = "web" })`.

## 2. HiDPI coordinate-space mismatch — DONE (v0.5.2, `510d970`)

Resolution: CSS pixels picked as the public contract. Mouse coords no
longer scale by `canvas.width/clientWidth`, and `resize(w, h)` now
receives `clientWidth/clientHeight` (CSS pixels). Canvas backing is
still sized to `clientWidth * devicePixelRatio` for crisp rendering;
consumers needing the device-pixel size multiply by
`getDevicePixelRatio()` themselves. Contract documented in
`docs/ARCHITECTURE.md` and on the `InputState` doc comment.


**Problem.** In the generated `dist/app.js`:

- `viewport_width / viewport_height` are filled from
  `window.innerWidth / innerHeight` — **CSS pixels**.
- `mouse_x / mouse_y` are computed as `e.offsetX * (canvas.width /
  canvas.clientWidth)` — **canvas backing pixels** (device pixels when
  DPR ≥ 1 and canvas width is set via the attribute).
- `device_pixel_ratio` is exposed but no one in the binding uses it
  consistently.

On a Retina-class display (DPR = 2), teak will (a) size its viewport at
CSS pixels but (b) receive mouse coords that are 2× larger — hit-tests
miss by a factor of DPR.

**Teak workaround.** Not applied yet. At DPR = 1 (typical desktop
Chrome with no zoom) the bug is invisible. Will surface as a "clicks
miss everything" on HiDPI.

**Ask.** Pick one coordinate space (strong recommendation: CSS pixels
for both viewport + mouse) and document it as the contract. Either:

- scale `mouse_x/y` by `1 / sx` in `flush()` so they too land in CSS
  pixels, OR
- set `canvas.width = clientWidth * devicePixelRatio` explicitly and
  report `viewport_width = canvas.width` (device pixels everywhere).

The former is cheaper to adopt — consumers want logical coords in most
cases.

## 3. `typed_chars` buffer bleeds non-text keys — DONE (PR #9, `fd68ff5`)

The generated keydown handler now gates `typedChars.push` on
`e.key.length === 1 && charCode >= 0x20 && charCode !== 0x7f`. No
explicit Backspace/Enter appends. Teak's handoff doc predated the fix.


**Problem.** The generated JS pushes `Backspace` → `0x08` and `Enter`
→ `0x0A` into `typed_chars` while also setting the corresponding bits
in `keys_pressed`. Consumers that route typed chars into a text input
end up both *inserting the byte* and *applying the backspace/enter
semantic* on the same keystroke.

**Teak workaround.** Teak's counter_greeter app has a `name_char` path
that accepts any u8 — so today a Backspace keystroke inserts byte 8
*and* deletes a char. Visible glitch. The test app only has a tiny
input; we'll filter control chars client-side if it proves annoying
before zunk ships a fix.

**Ask.** In the generated `flush()` / keydown handler, gate the
`typedChars.push` on `e.key.length === 1 && !e.ctrlKey && !e.altKey &&
!e.metaKey` only — drop the explicit Backspace/Enter appends. The keys
bitmap already covers those.

## 4. Missing keys in `zunk.web.input.Key` — DONE (v0.5.1, `4f1dbbe`)

Added: `page_up` (33), `page_down` (34), `end` (35), `home` (36),
`insert` (45), `delete` (46).


**Problem.** The enum covers alpha, digits, F1–F12, arrows, and common
modifiers — but omits `Delete` (46), `Home` (36), `End` (35), `PageUp`
(33), `PageDown` (34), `Insert` (45).

**Teak workaround.** Teak's `SpecialKey` enum has `.delete`, `.home`,
`.end` but wasm maps nothing into them. Text-input cursor navigation on
web is limited to `Left/Right` until zunk extends `Key`.

**Ask.** Add the five codes above (they're stable JS keycodes) to the
enum. One-line change in `zunk/src/web/input.zig`.

## 5. No mouse edge events — DONE (v0.5.3, `f12aabb`)

`InputState` now carries `mouse_buttons_pressed` and
`mouse_buttons_released` u8 bitmaps, cleared each flush. Query via
`isMouseButtonPressed(.left)` / `isMouseButtonReleased(.left)` (new
`MouseButton` enum: `left=0, middle=1, right=2`). Teak can drop the
`prev_left` diff in `src/platform/wasm.zig`.


**Problem.** `mouse_buttons` is current state. Consumers that care
about "click" (mouse down followed by mouse up over the same element)
have to diff across polls themselves.

**Teak workaround.** `src/platform/wasm.zig` stores
`prev_left: bool`, diffs each poll, and synthesizes
`mouse_down/mouse_up` for teak's `InputState`. Works fine.

**Ask (low priority).** Optional — add
`mouse_buttons_pressed / mouse_buttons_released` bitmaps analogous to
`keys_pressed / keys_released`. If not adopted, not blocking; the
client-side diff is three lines.

## 6. (Docs) Canvas ownership & resize — DONE (v0.5.3, `f12aabb`)

New "Canvas ownership and resize contract" paragraph in the Lifecycle
Protocol section of `docs/ARCHITECTURE.md`. Contract: zunk owns
`canvas.width/height`, sizes the backing store to device pixels, and
calls `resize(w, h)` with CSS pixels. Consumers never touch the canvas
attributes directly.


**Problem.** The generated HTML uses `<canvas id="app">` with CSS
sizing, but the JS never sets `canvas.width / canvas.height`
attributes to match. Consumers that want crisp pixel-perfect rendering
at the backing resolution have to either (a) run a `ResizeObserver`
from their wasm and call `resize(w, h)`, or (b) trust the browser's
auto-stretch. Neither path is documented.

**Teak workaround.** Teak relies on the user-exported `resize(w, h)`
being called by zunk's runtime on window resize. Verified: it is. But
the `w, h` passed to that export are `window.innerWidth / innerHeight`
(CSS pixels) — so the shader's `screen_size` uniform ends up in the
same CSS-pixel space that `mouse_x/y` uses (see §2 above). As long as
the DPR-inconsistency in §2 is resolved, this is fine.

**Ask.** Document the contract: what units does `resize(w, h)` carry,
and does zunk promise to resize the canvas backing to match?

## 7. (Nice-to-have) `clearRetainingCapacity` friendly FBA story — DONE (docs, v0.5.3, `f12aabb`)

New "Per-Frame Allocation Pattern" section in `docs/ARCHITECTURE.md`
documenting the `ArenaAllocator + reset(.retain_capacity)` idiom,
contrasted with `FixedBufferAllocator`'s no-piecewise-free footgun.
Documented as a convention, not shipped as a zunk API (zunk stays
allocator-agnostic).


Not a zunk issue — a wasm-idiom pattern that is missing a good story.
Teak's `web_main.zig` uses a 1 MiB `FixedBufferAllocator` that grows
forever (no piecewise free). For larger apps a watermark-reset-between-
frames allocator (`std.heap.ArenaAllocator` but with `.reset(.retain_capacity)`
at end of frame) would be ideal.

The FBA works because `CmdBuffer` and `verts: ArrayList` both use
`clearRetainingCapacity`/`reset` and don't free. If zunk offered an
official "per-frame arena" helper (or even just docs on the pattern),
that'd help the next consumer.

---

## Zunk version pinned by teak

Currently a path dep: `.zunk = .{ .path = "../zunk" }` in teak's root
`build.zig.zon`. All seven items landed in zunk v0.5.3 — ready to
switch to a tagged git URL at `v0.5.3` (or later).
