---
name: test
description: Run zig build test
---

# /test - Run Tests

Run `zig build test -j4` for the blocking end-to-end gate. Run `zig build test-heavy -j4` separately for the background gate. Follow [ENGINEERING.md](https://github.com/hotschmoe/hotschmoe-setup/blob/master/ENGINEERING.md).

## Usage

```
/test [--optimize=<level>]
```

## Options

| Option | Values | Default | Description |
|--------|--------|---------|-------------|
| `--optimize` | Debug, ReleaseSafe, ReleaseFast, ReleaseSmall | Debug | Optimization level |

## Examples

- `/test` - Run tests with default (Debug) optimization
- `/test --optimize=ReleaseSafe` - Run tests with ReleaseSafe optimization

## What It Does

1. Executes: `zig build test [-Doptimize=<level>]`
2. Reports test results (pass/fail)
3. Shows any test failures with details

## When to Use

- After making code changes
- Before committing
- Quick regression check
- CI validation

## Implementation

```bash
# Default (Debug)
zig build test -j4

# With optimization
zig build test -j4 -Doptimize=ReleaseSafe
```
