# Zig 0.15.2 -> 0.16.0 Migration Investigation

Status: investigation only. No code changed. This doc captures everything needed
to execute the migration once `webzocket` and `rich_zig` deps are updated.

## TL;DR

Zig 0.16.0 shipped the **I/O Interface rewrite**. `std.fs`, `std.net`, `std.process`,
`std.Thread.sleep`, and the `std.io.Writer` ecosystem were all refactored. Nearly
every syscall-adjacent call site in zunk's native CLI needs rework. The
wasm32-freestanding library (`src/root.zig`, `src/bind/`, `src/web/`) does no
stdlib I/O and is almost certainly unaffected.

Migration order:
1. Update `webzocket` upstream -> push new commit, update hash in `build.zig.zon`.
2. Update `rich_zig` upstream -> push new commit, update hash in `build.zig.zon`.
3. Migrate zunk native CLI (`src/main.zig`, `src/gen/*.zig`).

## Verified stdlib changes in 0.16.0

Paths below are absolute in the local Zig install: `C:\zig\lib\std\`.

### Removed / moved to `std.Io`

| Old (0.15.2)                          | New (0.16.0)                                          |
|---------------------------------------|-------------------------------------------------------|
| `std.fs.cwd()`                        | `std.Io.Dir.cwd()` (all `Dir`/`File` ops now need `io: Io`) |
| `std.fs.Dir`                          | `std.Io.Dir`                                          |
| `std.fs.File`                         | `std.Io.File`                                         |
| `std.fs.max_path_bytes`               | `std.Io.Dir.max_path_bytes`                           |
| `std.fs.path.basename/extension/...`  | `std.Io.Dir.path.basename/extension/...`              |
| `std.net.Address.initIp4`             | `std.Io.net.IpAddress`                                |
| `std.net.Stream`                      | `std.Io.net.Stream` (no more raw `.handle`; use `.Reader`/`.Writer`) |
| `std.net.tcpConnectToHost`            | new API under `std.Io.net`                            |
| `std.process.argsAlloc/argsFree`      | `std.process.Args.Iterator.initAllocator(args, gpa)`  |
| `std.process.Child.init/spawn/wait/collectOutput` | `std.process.spawn(io, opts)`, `.wait(io)`, no `collectOutput` (use `std.process.run` or manual pipe reads) |
| `std.Thread.sleep`                    | `io.sleep(duration, clock)` (on `Io` interface)       |
| `std.mem.trimLeft`                    | `std.mem.trimStart`                                   |
| `std.mem.trimRight`                   | `std.mem.trimEnd`                                     |
| `Compile.linkLibC()`                  | `compile.root_module.link_libc = true;` or `module.linkSystemLibrary("c", .{})` |
| `ArrayList(u8).writer(allocator)`     | `std.Io.Writer.Allocating.fromArrayList(gpa, &list)` -> `.writer` |

### Unchanged (safe to keep as-is)

- `std.mem.indexOf`, `indexOfScalar`, `eql`, `startsWith`, `endsWith`,
  `splitSequence`, `readInt`, `writeInt`, `trim`, `sliceTo` (aliases to `find*` in 0.16 but same API)
- `std.fmt.bufPrint`, `allocPrint`, `bytesToHex`, `parseInt`
- `std.base64.standard.Encoder.calcSize/encode`
- `std.crypto.hash.sha2.Sha384`
- `std.hash.XxHash3.hash`
- `std.Thread.spawn` (still exists for detached threads; only `sleep` moved)
- `std.ArrayList(T)` unmanaged pattern: `.empty`, `.deinit(allocator)`,
  `.append(allocator, item)`, `.toOwnedSlice(allocator)`, `.items` field
- `std.Build` methods (`addModule`, `createModule`, `addExecutable`, `addTest`,
  `addRunArtifact`, `dependency`, `installArtifact`, `path`, `fmt`, `step`,
  `graph.host`, `standardTargetOptions`, `standardOptimizeOption`) — all unchanged

### New: `std.Io.Writer` pattern

The `std.io.Writer(context, Error, writeFn)` generic is replaced by a vtable-
based `std.Io.Writer` struct:

```zig
pub const Writer = struct {
    vtable: *const VTable,
    buffer: []u8,
    end: usize = 0,
    pub fn print(w: *Writer, comptime fmt: []const u8, args: anytype) Error!void
    pub fn writeAll(w: *Writer, bytes: []const u8) Error!void
    ...
};
```

For "fill an ArrayList via writer", the bridge is `std.Io.Writer.Allocating`:

```zig
var list: std.ArrayList(u8) = .empty;
defer list.deinit(allocator);

var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &list);
defer list = aw.toArrayList();   // sync any appends back into `list`

try aw.writer.print("hello {s}", .{"world"});
try aw.writer.writeAll("more bytes");
```

Or use `ArrayList.print` directly for one-shot formatted appends:

```zig
try list.print(allocator, "hello {s}", .{"world"});
```

## The `Io` instance question

In 0.16 most syscall APIs require an `Io` value. The standard "synchronous,
threaded" implementation is `std.Io.Threaded`. Typical main looks like:

```zig
pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var threaded: std.Io.Threaded = try .init(allocator);
    defer threaded.deinit();
    const io = threaded.io();

    // ... thread `io` through everything
}
```

Every fn that touches fs/net/process/sleep needs `io: std.Io` threaded in. For
zunk this means adding `io` to `BuildContext`, `ServeConfig`, and most helper
signatures. Practical approach: add an `io` field to a top-level context struct
(or just pass it alongside `allocator` the same way).

## Files in zunk that need migration

### Native CLI (must migrate)

**`src/main.zig`** (~30 call sites)
- L14-15:   `std.process.argsAlloc/argsFree` -> `Args.Iterator.initAllocator`
- L159, 368: `std.fs.cwd().readFileAlloc(alloc, path, max)` -> `std.Io.Dir.cwd().readFileAlloc(io, path, gpa, limit)` (signature now: `dir, io, sub_path, gpa, limit`)
- L173, 298: `std.fs.path.basename/extension` -> `std.Io.Dir.path.basename/extension`
- L196-198: `std.fs.Dir`, `cwd().makePath`, `cwd().openDir` -> `std.Io.Dir`, needs `io` param
- L321-323: `html.writer(allocator)` -> `std.Io.Writer.Allocating.fromArrayList(...)` (`generateHtml` signature changes in js_gen.zig too)
- L378-399: `std.fs.Dir`, `openDir`, `readFileAlloc`, `writeFile`, `walk`, `makePath` — all need `io`
- L419, 427, 435: `openFile`, `stat` — new `Io.File` API
- L445, 451, 468, 479: `openDir`, `max_path_bytes` — move to `std.Io.Dir`
- L504: `std.process.Child.run(.{...})` -> `std.process.run(io, .{...})` (sig change)
- L546, 578: `std.fs.cwd().access` -> `Io.Dir.cwd().access(io, path, .{})`
- L649, 660: `std.fs.cwd()`, `std.fs.Dir` -> `Io.Dir.cwd()`, `std.Io.Dir`
- L768: `.minimum_zig_version = "0.15.2"` in the scaffold template — bump to "0.16.0"

**`src/gen/serve.zig`** (heaviest — net + threads + process + fs)
- L9:       `std.net.Stream.Handle` -> new socket handle location in `std.Io.net`
- L89:      `std.fs.cwd().openDir` -> `std.Io.Dir.cwd().openDir(io, ...)`
- L102-103: `std.net.Address.initIp4(...).listen(...)` -> `std.Io.net.IpAddress` + new listen API
- L135, 156, 205, 492, 534: function signatures taking `std.net.Stream`, `std.fs.Dir` — all must take `std.Io.net.Stream`, `std.Io.Dir`, and `io: std.Io`
- L176, 182: `root_dir.readFileAlloc` — new sig
- L181, 475: `std.fs.path.extension` -> `std.Io.Dir.path.extension`
- L236:     `std.mem.trimLeft` -> `std.mem.trimStart`
- L276, 309, 311: `std.Thread.sleep` -> `try io.sleep(Duration.fromMillis(500), .monotonic)` (or wall clock)
- L319-320: `std.process.Child.init(argv, alloc)` -> `std.process.spawn(io, .{ .argv = ..., ... })`
- L332:     `child.collectOutput(alloc, &stdout, &stderr, max)` — `collectOutput` does not exist in 0.16; replace with `std.process.run(io, .{...})` which returns `Output { stdout, stderr, term }`, OR manually read from `child.stdout.?` / `child.stderr.?` pipes using the new `std.Io.File.Reader` API
- L334:     `child.wait()` -> `child.wait(io)`
- L372, 386, 392: `openFile`/`openDir`/`max_path_bytes` — `std.Io.Dir`
- L508:     `std.net.tcpConnectToHost(alloc, host, port)` -> new `std.Io.net` connect API
- L514:     `rewritten.writer(allocator)` -> `Writer.Allocating` or drop `w.print/writeAll` in favor of `rewritten.print(allocator, ...)`
- L429-465: Windows raw socket code (`windows.ws2_32.recv/send`, `std.posix.read/write` against `stream.handle`) — `Stream` no longer exposes `.handle` directly; rework to use `Stream.Reader`/`Stream.Writer`, or access the socket through the new `std.Io.net.Socket` abstraction. This block is the largest unknown.

**`src/gen/js_gen.zig`**
- L72, 74:  `js.writer(allocator)` pattern — rework with `Writer.Allocating` OR change `generate*` functions to take `*std.ArrayList(u8)` and use `.print(gpa, ...)` / `.appendSlice(gpa, ...)` directly. The `*std.ArrayList(u8)` approach is simpler and has no perf cost.
- L214-216, 218-220: same pattern

**`src/gen/js_resolve.zig`**
- L788, 790: same `.writer(allocator)` pattern as js_gen.zig

**`src/gen/wasm_analyze.zig`**
- Only uses `std.ArrayList(T)` with `.empty` + `.append(allocator, item)` + `.deinit(allocator)` — **no changes needed**. No I/O.

### Not affected (wasm32-freestanding library)

- `src/root.zig`
- `src/bind/bind.zig`
- `src/web/*.zig` (canvas, input, audio, asset, app, ui, gpu, imgui, render_backend)

These use only `extern "env" fn ...` + @typeInfo + memory stuff, no stdlib I/O.
They compile for `wasm32-freestanding` which cannot call these APIs anyway.

### Build files

**`build.zig`** — all APIs used are unchanged in 0.16. Should compile as-is
once deps compile.

**`build.zig.zon`** — `.minimum_zig_version = "0.16.0"` already set. Update
hashes after dep commits land.

## What the deps need

### webzocket

The only error currently visible is:
```
build.zig:25  tests.linkLibC();   // -> fails: linkLibC removed from Compile
```

Fix:
```zig
tests.root_module.link_libc = true;
// or equivalently:
// tests.root_module.linkSystemLibrary("c", .{});
```

Likely additional work (haven't audited `src/client/`, `src/server/`,
`src/websocket.zig`, `src/proto.zig` yet):
- Any `std.net.Stream` / `std.net.Address` / `std.net.tcpConnectToHost` usage
- Any `std.posix` raw socket I/O interacting with `Stream.handle` — the handle
  access pattern changed
- Any `std.Thread.sleep` or `std.process.Child` usage
- Any `std.fs` file reads (test fixtures, build-time assets)
- Any `ArrayList.writer(...)` or old `std.io.Writer` interface usage
- `std.mem.trimLeft/trimRight` renames

Happy to audit webzocket's src/ when you're ready — just say the word.

### rich_zig

I haven't read the source yet. Expected hotspots based on the file list
(`ansi.zig`, `console.zig`, `terminal.zig`, `highlighter.zig`, renderables, etc.):
- `std.io.getStdOut()` / `getStdErr()` — the whole writer stack moved to `std.Io.Writer`
- Any `std.ArrayList.writer(...)` calls in the renderer pipeline
- Terminal detection likely uses `std.posix` tcgetattr / `std.os.windows.kernel32` — unchanged surface but may depend on deprecated re-exports in `std.fs`
- `trimLeft`/`trimRight` renames (common in ANSI parsing)
- Any `std.fs` file reads (theme loading?)

If you want, I can audit rich_zig too once you're looking at it.

## Open questions

1. **`std.net.Stream.handle` replacement.** `serve.zig` reads/writes raw socket
   bytes via Windows `ws2_32` and `std.posix`. The new `std.Io.net.Stream` wraps
   its transport differently. Will need to confirm whether to (a) use the new
   `Stream.Reader`/`Stream.Writer`, (b) reach through to a raw socket handle,
   or (c) rewrite using `std.Io.net.Socket`. This is the biggest zunk-side
   unknown.

2. **Dev server threading model.** With sleep on `Io` and spawn on `std.Thread`
   (unchanged), we need the `Io` instance accessible from watcher threads.
   Confirm whether `Io.Threaded` instances can be shared across threads (the
   header comment says "Thread-safe" for its vtable fns, so yes — but
   the `io()` value needs to be captured in each spawned thread closure).

3. **Writer strategy for `js_gen`/`js_resolve`.** Two viable paths:
   - (a) Rework signatures to take `*std.ArrayList(u8)` directly and use
     `.print(gpa, ...)` / `.appendSlice(gpa, ...)` — simpler, fewer types.
   - (b) Keep `*std.Io.Writer` signatures, use `Writer.Allocating` at call
     sites — more flexible if we ever write directly to a file/socket/etc.

   Recommendation: **(a)** for now, since all output is buffered to an
   ArrayList anyway and then written. Cleaner code, fewer abstractions.

## Suggested implementation order for zunk-side migration

1. Add `Io.Threaded` init in `main.zig`, capture `io` into a context struct.
2. Rename `trimLeft` -> `trimStart` (serve.zig:236) — one-line, risk-free.
3. Rework `js_gen.zig` + `js_resolve.zig` writer signatures to take
   `*std.ArrayList(u8)` (no `Io` needed — pure in-memory).
4. Migrate `main.zig` fs/process calls with `io` threaded through.
5. Migrate `serve.zig` fs/process/sleep.
6. Migrate `serve.zig` networking last (biggest unknown, isolate until others
   compile).
7. Update `src/main.zig:768` scaffold template's `minimum_zig_version` string.
8. Test: `zig build`, `zig build test`, `zig build run` against an example.

## Ground truth files referenced

- `C:\zig\lib\std\fs.zig` — 21 lines, all deprecation aliases to `std.Io.Dir`
- `C:\zig\lib\std\process.zig` — `spawn(io, opts)`, `run(io, opts)`
- `C:\zig\lib\std\process\Args.zig` — new `Args.Iterator` API
- `C:\zig\lib\std\Thread.zig` — `spawn` present, **no `sleep`**
- `C:\zig\lib\std\Io.zig` — `sleep(io, duration, clock)` at line 2397
- `C:\zig\lib\std\Io\Threaded.zig` — default `Io` impl
- `C:\zig\lib\std\Io\Writer.zig:2502` — `Allocating` struct
- `C:\zig\lib\std\array_list.zig:1042` — new `.print(gpa, fmt, args)`
- `C:\zig\lib\std\mem.zig:1180` — `trimStart` (no `trimLeft`)
- `C:\zig\lib\std\Build\Step\Compile.zig` — no `linkLibC` method;
  `link_libc` is a `Module` field
