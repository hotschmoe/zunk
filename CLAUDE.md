<!-- BEGIN:header -->
# CLAUDE.md

we love you, Claude! do your best today
<!-- END:header -->

<!-- BEGIN:rule-1-no-delete -->
## RULE 1 - NO DELETIONS (ARCHIVE INSTEAD)

You may NOT delete any file or directory. Instead, move deprecated files to `.archive/`.

**When you identify files that should be removed:**
1. Create `.archive/` directory if it doesn't exist
2. Move the file: `mv path/to/file .archive/`
3. Notify me: "Moved `path/to/file` to `.archive/` - deprecated because [reason]"

**Rules:**
- This applies to ALL files, including ones you just created (tests, tmp files, scripts, etc.)
- You do not get to decide that something is "safe" to delete
- The `.archive/` directory is gitignored - I will review and permanently delete when ready
- If `.archive/` doesn't exist and you can't create it, ask me before proceeding

**Only I can run actual delete commands** (`rm`, `git clean`, etc.) after reviewing `.archive/`.
<!-- END:rule-1-no-delete -->

<!-- BEGIN:irreversible-actions -->
### IRREVERSIBLE GIT & FILESYSTEM ACTIONS

Absolutely forbidden unless I give the **exact command and explicit approval** in the same message:

- `git reset --hard`
- `git clean -fd`
- `rm -rf`
- Any command that can delete or overwrite code/data

Rules:

1. If you are not 100% sure what a command will delete, do not propose or run it. Ask first.
2. Prefer safe tools: `git status`, `git diff`, `git stash`, copying to backups, etc.
3. After approval, restate the command verbatim, list what it will affect, and wait for confirmation.
4. When a destructive command is run, record in your response:
   - The exact user text authorizing it
   - The command run
   - When you ran it

If that audit trail is missing, then you must act as if the operation never happened.
<!-- END:irreversible-actions -->

<!-- BEGIN:code-discipline -->
### Code Editing Discipline

- Do **not** run scripts that bulk-modify code (codemods, invented one-off scripts, giant `sed`/regex refactors).
- Large mechanical changes: break into smaller, explicit edits and review diffs.
- Subtle/complex changes: edit by hand, file-by-file, with careful reasoning.
- **NO EMOJIS** - do not use emojis or non-textual characters.
- ASCII diagrams are encouraged for visualizing flows.
- Keep in-line comments to a minimum. Use external documentation for complex logic.
- In-line commentary should be value-add, concise, and focused on info not easily gleaned from the code.
<!-- END:code-discipline -->

<!-- BEGIN:no-legacy -->
### No Legacy Code - Full Migrations Only

We optimize for clean architecture, not backwards compatibility. **When we refactor, we fully migrate.**

- No "compat shims", "v2" file clones, or deprecation wrappers
- When changing behavior, migrate ALL callers and remove old code **in the same commit**
- No `_legacy` suffixes, no `_old` prefixes, no "will remove later" comments
- New files are only for genuinely new domains that don't fit existing modules
- The bar for adding files is very high

**Rationale**: Legacy compatibility code creates technical debt that compounds. A clean break is always better than a gradual migration that never completes.
<!-- END:no-legacy -->

<!-- BEGIN:dev-philosophy -->
## Development Philosophy

**Make it work, make it right, make it fast** - in that order.

**This codebase will outlive you** - every shortcut becomes someone else's burden. Patterns you establish will be copied. Corners you cut will be cut again.

**Fight entropy** - leave the codebase better than you found it.

**Inspiration vs. Recreation** - take the opportunity to explore unconventional or new ways to accomplish tasks. Do not be afraid to challenge assumptions or propose new ideas. BUT we also do not want to reinvent the wheel for the sake of it. If there is a well-established pattern or library take inspiration from it and make it your own. (or suggest it for inclusion in the codebase)
<!-- END:dev-philosophy -->

<!-- BEGIN:testing-philosophy -->
## Testing

Follow [ENGINEERING.md](https://github.com/hotschmoe/hotschmoe-setup/blob/master/ENGINEERING.md): no unit tests, at most ten blocking end-to-end tests, and a separate background gate. Do not add snapshots or tests of implementation structure.

Run `zig build test -j4` for the blocking gate and `zig build test-heavy -j4` for the background gate. Both require Node.js; the background gate also requires Chromium or Google Chrome (set `CHROME_BIN` to override detection). The background gate runs on a schedule and does not block pull requests; investigate failures by finding the regressing commit and fixing head.
<!-- END:testing-philosophy -->

<!-- BEGIN:footer -->
---

we love you, Claude! do your best today
<!-- END:footer -->


---

## Project-Specific Content

<!-- This section will not be touched by haj.sh -->

### What is zunk

zunk is a build tool and runtime library for writing browser applications entirely in Zig, compiled to WebAssembly. It generates all HTML and JavaScript from the compiled `.wasm`: it reads the binary's imports and exports, emits only the JS bridge code those imports need, and serves or deploys the result. Its main consumer is [teak](https://github.com/hotschmoe/teak), which uses `zunk.web.gpu`, `web.input`, `web.fx` and `web.ime` for its web backend.

### Toolchain

- **Language**: Zig 0.17 (`minimum_zig_version` in `build.zig.zon`; CI pins `ZIG_VERSION` in `.github/workflows/ci.yml`)
- **Build**: `zig build` (native CLI), `zig build run -- <args>` (run the CLI)
- **Gates**: `zig build test -j4` is the blocking end-to-end gate (needs Node); `zig build test-heavy -j4` is the background gate (needs Node and Chrome/Chromium). Both run `tools/test.mjs`. There are no unit tests; see ENGINEERING.md.
- **Target**: the zunk CLI is a native executable; user projects compile to `wasm32-freestanding`
- **Dependencies**: `webzocket` (dev-server WebSocket) and `rich_zig` (CLI output), both pinned in `build.zig.zon`

### Project Structure

```
build.zig              -- CLI build, test steps, and installApp() for consumer build.zig files
src/
  root.zig             -- the "zunk" module: bind, web.*, version
  main.zig             -- CLI: build, run, deploy, init, doctor, help, version
  bind/bind.zig        -- Handle, callback table, 64 KB string exchange buffer
  web/                 -- typed wrappers imported by wasm apps
    app.zig, asset.zig, audio.zig, canvas.zig, input.zig
    gpu.zig            -- WebGPU
    fx.zig             -- host services (fetch, downloads, file pick, storage, clipboard, paste/drop)
    ime.zig            -- IME composition bridge
    ui.zig             -- HTML overlay controls
    imgui.zig, render_backend.zig -- immediate-mode canvas UI
  gen/                 -- the build tool (native only)
    wasm_analyze.zig   -- WASM binary parser
    js_resolve.zig     -- import name -> JS body resolution
    js_gen.zig         -- JS + HTML generator, build report
    source_map.zig     -- source maps for bridge.js chunks
    serve.zig          -- dev server, watcher, live reload, HMR
    js/                -- embedded JS for a11y, fx and ime
examples/              -- 12 example apps, each with its own build.zig
tools/test.mjs         -- both gates
tools/release.sh       -- cut a release
docs/                  -- ARCHITECTURE.md, ROADMAP.md, VERSIONING.md, design notes
SRC.md                 -- per-module notes the code cannot say
ref/                   -- prior art (read-only)
```

### Architecture Overview

```
Zig source --> zig build (wasm32) --> .wasm binary
                                        |
                                   WASM Analyzer
                                   (imports, exports, types, names)
                                        |
                                   Resolution Engine
                                   T1: Exact match (known name)
                                   T2: Prefix match (namespace convention)
                                   T3: Signature (types + name keywords)
                                   T4: Param names (debug section hints)
                                   T5: Stub (warning + build report)
                                        |
                                   JS Code Generator
                                   (emit only what the WASM imports)
                                        |
                                   dist/
                                     index.html, app.js, <name>.wasm
                                     (deploy: app-<hash>.js, <name>-<hash>.wasm, SRI)
```

A new browser binding has two halves that must change together: the `extern "env" fn` and wrapper in `src/web/*.zig`, and its JS body in `src/gen/js_resolve.zig` (or the `zunkGPU` helper in `src/gen/js_gen.zig`). Descriptor layouts and enum orders are shared by position.

### Key Design Decisions

- **No JavaScript, no HTML** -- everything is generated from WASM analysis
- **Polling-based input** -- shared memory struct, not event callbacks
- **Handle table** for opaque JS objects (integer ID <-> JS object)
- **Strings**: ptr+len into WASM linear memory (Zig->JS), shared 64 KB exchange buffer (JS->Zig)
- **Adaptive output** -- only emit JS scaffolding for features the WASM uses

### Three Usage Paths (all coexist)

1. **Raw extern fns** -- declare `extern "env" fn` with naming conventions, zunk auto-resolves
2. **Layer 2 modules** -- `@import("zunk").web.canvas` etc., typed Zig wrappers
3. **bridge.js escape hatch** -- custom JS appended to the generated output; a library ships one via `installApp`'s `bridge_deps`

### WASM Lifecycle Exports

| Export    | Signature              | When Called                    |
|-----------|------------------------|--------------------------------|
| `init`    | `fn () void`          | Once after WASM + canvas ready |
| `frame`   | `fn (dt: f32) void`   | Every requestAnimationFrame    |
| `resize`  | `fn (w: u32, h: u32) void` | On window resize          |
| `cleanup` | `fn () void`          | On beforeunload                |

### Current Status

Everything above is implemented. `docs/ROADMAP.md` lists what is open; `SRC.md` holds the invariants.

## Versioning
`build.zig.zon` `.version` is the single source of truth; code reads `zunk.version` (from `build_options`). Never write a version literal elsewhere, never bump it in a feature PR. Releases are cut explicitly with `tools/release.sh <semver>`. See [`docs/VERSIONING.md`](docs/VERSIONING.md).
