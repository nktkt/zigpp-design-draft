# Diagnostics

This document describes the current prototype diagnostics for Zig++ source.
The diagnostics are intentionally conservative and local. They are meant to
catch visible-cost violations while the parser and semantic analysis are still
small.

Diagnostic output uses this shape:

```text
path/to/file.zpp:line:column: severity: message
```

Current severities are:

- `error`: fails `zpp --check`, `zpp-audit`, and `zpp-package --audit`
- `warning`: reports by default and fails only with `--deny-warnings` or
  `-Werror`
- `note`: available in the diagnostic model, but not currently emitted by the
  main checks

Stable diagnostic codes do not exist yet. Until they do, tests and tooling
should match severity and message text only when necessary.

## Commands

Run diagnostics for one file:

```sh
./zig-out/bin/zpp examples/effects_visibility.zpp --check
```

Treat warnings as failures:

```sh
./zig-out/bin/zpp examples/effects_visibility.zpp --check --deny-warnings
```

Audit several files:

```sh
./zig-out/bin/zpp-audit examples/hello_trait.zpp examples/noalloc_hash.zpp
```

Audit a package manifest:

```sh
zig build package-zpp -- zpp-package.json --audit
```

## Ownership Diagnostics

Ownership diagnostics are driven by `own var`, `move`, `using`, and explicit
`.deinit()` calls.

### Missing Cleanup

Message:

```text
owned value must be paired with `using name;` or `name.deinit()`
```

Example:

```zig
pub fn main() !void {
    own var buf = try Buffer.init(allocator);
    _ = buf;
}
```

Fix:

```zig
pub fn main() !void {
    own var buf = try Buffer.init(allocator);
    using buf;
    _ = buf;
}
```

Rules:

- every local `own var` must be cleaned up or moved
- cleanup is recognized through `using name;` or `name.deinit()`
- this check is local and does not model full lifetimes

### Use After Move

Message:

```text
owned value used after move
```

Example:

```zig
pub fn main() !void {
    own var buf = try Buffer.init(allocator);
    var moved = move buf;
    _ = buf;
    using moved;
}
```

Fix:

```zig
pub fn main() !void {
    own var buf = try Buffer.init(allocator);
    var moved = move buf;
    _ = moved;
    using moved;
}
```

Rules:

- the moved-from name cannot be used after `move`
- cleanup of the moved-from name is also rejected
- the move destination becomes responsible for cleanup

### Move After Cleanup

Message:

```text
owned value moved after deinit
```

Example:

```zig
pub fn main() !void {
    own var buf = try Buffer.init(allocator);
    using buf;
    var moved = move buf;
    using moved;
}
```

Rules:

- a value cannot be moved after `using name;` or `name.deinit()`
- this protects against transferring an already-cleaned-up resource

### Double Cleanup

Message:

```text
owned value deinitialized more than once
```

Example:

```zig
pub fn main() !void {
    own var buf = try Buffer.init(allocator);
    using buf;
    buf.deinit();
}
```

Fix:

```zig
pub fn main() !void {
    own var buf = try Buffer.init(allocator);
    using buf;
}
```

Rules:

- `using name;` counts as a cleanup
- `name.deinit()` counts as a cleanup
- the same local owned value may only be cleaned up once

## Effect Diagnostics

Effect diagnostics are active inside functions with an `effects(...)`
annotation. The checker looks for known source patterns and classifies them as
allocation-like, I/O-like, blocking-like, spawn-like, dynamic-dispatch-like, or
unsafe-like operations.

Effect diagnostics are shallow by design. They are a CI guardrail, not a full
effect type system.

### Negative Effect Violations

Negative effects reject matching operations in the annotated function body.

| Effect | Message |
| --- | --- |
| `.noalloc` | `effects(.noalloc) function contains allocation-like operation` |
| `.noio` | `effects(.noio) function contains I/O-like operation` |
| `.nonblocking` | `effects(.nonblocking) function contains blocking-like operation` |
| `.nothread` | `effects(.nothread) function contains spawn-like operation` |
| `.nodyn` | `effects(.nodyn) function contains dynamic-dispatch-like operation` |
| `.nounsafe` | `effects(.nounsafe) function contains unsafe-like operation` |

Example:

```zig
fn make(allocator: std.mem.Allocator) ![]u8
    effects(.noalloc)
{
    return try allocator.alloc(u8, 16);
}
```

Fix:

```zig
fn make(allocator: std.mem.Allocator) ![]u8
    effects(.alloc)
{
    return try allocator.alloc(u8, 16);
}
```

### Missing Visible Effects

When a function has an `effects(...)` list and performs a recognized operation,
the operation must be declared with either a positive or negative effect.

Warnings:

| Operation | Message |
| --- | --- |
| allocation-like | `effects list must include .alloc for allocation-like operation` |
| I/O-like | `effects list must include .io for I/O-like operation` |
| blocking-like | `effects list must include .blocking for blocking-like operation` |
| spawn-like | `effects list must include .spawn for spawn-like operation` |
| dynamic-dispatch-like | `effects list must include .dyn for dynamic-dispatch-like operation` |
| unsafe-like | `effects list must include .unsafe for unsafe-like operation` |

Example:

```zig
fn addr(ptr: *u8) usize
    effects(.cpu)
{
    return @intFromPtr(ptr);
}
```

Fix:

```zig
fn addr(ptr: *u8) usize
    effects(.cpu, .unsafe)
{
    return @intFromPtr(ptr);
}
```

Rules:

- missing visible effects are warnings by default
- `--deny-warnings` promotes these warnings to failures
- positive effects such as `.alloc`, `.io`, `.blocking`, `.spawn`, `.dyn`, and
  `.unsafe` document that the cost may occur
- negative effects such as `.noalloc` and `.nounsafe` reject the matching
  operation

## Recognized Effect Patterns

The current checker uses simple source-pattern detection.

Allocation-like patterns include:

- `.alloc(`
- `.create(`
- `.dupe(`
- `.realloc(`
- `readFileAlloc(`
- `toOwnedSlice(`
- `std.heap.`

I/O-like patterns include:

- `std.fs.`
- `.openFile(`
- `.createFile(`
- `.readAll(`
- `.readToEnd`
- `.writeAll(`
- `std.debug.print(`
- `stdout()`
- `stderr()`

Blocking-like patterns include:

- `std.time.sleep(`
- `.sleep(`
- `.join(`
- `.wait(`
- `.accept(`
- `.connect(`

Spawn-like patterns include:

- `std.Thread.spawn(`
- `Thread.spawn(`
- `.spawn(`
- `.spawnThread(`
- `TaskGroup`

Dynamic-dispatch-like patterns include:

- `dyn `
- `.Dyn`
- `.vtable`
- `vtable.`

Unsafe-like patterns include:

- `@ptrCast(`
- `@ptrFromInt(`
- `@intFromPtr(`
- `@alignCast(`
- `@constCast(`
- `@volatileCast(`
- `@fieldParentPtr(`
- `asm `

These patterns are intentionally visible and easy to audit. Future semantic
analysis can replace the implementation, but the goal should remain the same:
costs must be visible in source and generated Zig.

## Current Limits

- diagnostics do not have stable numeric or symbolic codes yet
- ownership analysis is local to a source file and does not model branches
- the checker strips line comments but does not parse full Zig syntax
- effect detection is pattern-based and may have false positives or false
  negatives
- warnings fail only when the caller opts into `--deny-warnings`
