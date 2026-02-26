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
## Testing Philosophy: Diagnostics, Not Verdicts

**Tests are diagnostic tools, not success criteria.** A passing test suite does not mean the code is good. A failing test does not mean the code is wrong.

**When a test fails, ask three questions in order:**
1. Is the test itself correct and valuable?
2. Does the test align with our current design vision?
3. Is the code actually broken?

Only if all three answers are "yes" should you fix the code.

**Why this matters:**
- Tests encode assumptions. Assumptions can be wrong or outdated.
- Changing code to pass a bad test makes the codebase worse, not better.
- Evolving projects explore new territory - legacy testing assumptions don't always apply.

**What tests ARE good for:**
- **Regression detection**: Did a refactor break dependent modules? Did API changes break integrations?
- **Sanity checks**: Does initialization complete? Do core operations succeed? Does the happy path work?
- **Behavior documentation**: Tests show what the code currently does, not necessarily what it should do.

**What tests are NOT:**
- A definition of correctness
- A measure of code quality
- Something to "make pass" at all costs
- A specification to code against

**The real success metric**: Does the code further our project's vision and goals?

**Don't test the type system**: When writing tests, do not add cases for invariants or errors already enforced by the static type system (e.g., type mismatches, missing required arguments, nullability violations, return type correctness, enum exhaustiveness). The type checker handles these at compile time. Test solely runtime behaviors, business rules, algorithmic logic, and edge cases using only valid typed inputs.
<!-- END:testing-philosophy -->

<!-- BEGIN:footer -->
---

we love you, Claude! do your best today
<!-- END:footer -->


---

## Project-Specific Content

<!-- This section will not be touched by haj.sh -->

### What is zunk

zunk is a build tool and runtime library for writing browser applications entirely in Zig, compiled to WebAssembly. It auto-generates all HTML and JavaScript -- the developer never writes either. One command (`zunk run`) compiles Zig to WASM, analyzes the binary's imports/exports, generates minimal JS bridge code, and serves the result.

### Toolchain

- **Language**: Zig (minimum 0.15.2, see `build.zig.zon`)
- **Build**: `zig build` (native CLI), `zig build test` (tests), `zig build run` (run CLI)
- **Target**: The zunk CLI is a native executable; user projects compile to `wasm32-freestanding`

### Project Structure

```
src/
  root.zig       -- library root (public API, the "zunk" module)
  main.zig       -- CLI entry point (imports "zunk" module)
ref/              -- reference material and prior art (read-only)
```

**Planned structure** (from README, not yet implemented):

```
src/
  zunk.zig                -- root module
  bind/bind.zig           -- Handle, CallbackFn, string exchange, comptime manifest
  web/                    -- Layer 2 ergonomic Web API wrappers
    canvas.zig, input.zig, audio.zig, app.zig
  gen/                    -- build tool: WASM analysis + JS generation
    wasm_analyze.zig      -- WASM binary parser
    js_resolve.zig        -- 5-tier auto-resolution engine
    js_gen.zig            -- JS + HTML code generator
```

### Architecture Overview

```
Zig source --> zig build (wasm32) --> .wasm binary
                                        |
                                   WASM Analyzer
                                   (read imports, exports, types, names)
                                        |
                                   5-Tier Resolution Engine
                                   T1: Exact match (known Web API name)
                                   T2: Prefix match (namespace convention)
                                   T3: Signature (types + name keywords)
                                   T4: Param names (debug section hints)
                                   T5: Stub (warning + build report)
                                        |
                                   JS Code Generator
                                   (emit only what WASM actually imports)
                                        |
                                   dist/
                                     index.html, app-[hash].js, app-[hash].wasm
```

### Key Design Decisions

- **No JavaScript, no HTML** -- everything is generated from WASM analysis
- **Polling-based input** -- shared memory struct, not event callbacks (game-friendly)
- **Handle table** for opaque JS objects (integer ID <-> JS object Map)
- **Strings**: ptr+len into WASM linear memory (Zig->JS), shared 64KB exchange buffer (JS->Zig)
- **Adaptive output** -- only emit JS scaffolding for features the WASM actually uses

### Three Usage Paths (all coexist)

1. **Raw extern fns** -- declare `extern "env" fn` with naming conventions, zunk auto-resolves
2. **Layer 2 modules** -- `@import("zunk").web.canvas` etc., typed Zig wrappers
3. **bridge.js escape hatch** -- ship custom JS alongside your project for unsupported APIs

### WASM Lifecycle Exports

| Export    | Signature              | When Called                    |
|-----------|------------------------|--------------------------------|
| `init`    | `fn () void`          | Once after WASM + canvas ready |
| `frame`   | `fn (dt: f32) void`   | Every requestAnimationFrame    |
| `resize`  | `fn (w: u32, h: u32) void` | On window resize          |
| `cleanup` | `fn () void`          | On beforeunload                |

### Current Status

Phase 1 (Foundation) -- project is freshly initialized. `src/root.zig` and `src/main.zig` are still zig-init boilerplate. The core modules (bind/, web/, gen/) described in the README are not yet implemented. `ref/` contains prior art and conversation dumps for reference.

### Versioning

Bump `.version` in `build.zig.zon` following SemVer rules at meaningful milestones (new features, breaking changes, bug fixes). CI enforces that every PR to `master` includes a version bump, and merging automatically creates a GitHub Release tagged with that version.

