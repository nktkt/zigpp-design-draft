# Zig++ Package API: `zigpp-examples`

Version: `0.1.0`

# Zig++ API: `examples/contracts.zpp`

## Function `at`

```zig
fn at(xs: []const u8, i: usize) u8
```

Contracts:
- `requires(i < xs.len)`
- `invariant(xs.len > 0)`

## Function `abs`

```zig
fn abs(x: i32) i32
```

Contracts:
- `ensures(result >= 0)`

## Function `main`

```zig
pub fn main() void
```

# Zig++ API: `examples/derive_user.zpp`

## Function `main`

```zig
pub fn main() void
```

# Zig++ API: `examples/effects_visibility.zpp`

## Function `visibleEffects`

```zig
fn visibleEffects(allocator: std.mem.Allocator, plugin: Plugin.Dyn, ptr: *u8, file: std.fs.File) !void
```

Effects: `effects(.alloc, .io, .unsafe, .dyn, .spawn, .blocking)`

# Zig++ API: `examples/hello_trait.zpp`

## Trait `Writer`

Methods:
- `fn write(self, bytes: []const u8) !usize;`

## Owned Struct `FileWriter`

## Function `emit`

```zig
fn emit(w: impl Writer, msg: []const u8) !void
```

## Function `main`

```zig
pub fn main() !void
```

# Zig++ API: `examples/noalloc_hash.zpp`

## Function `hashBytes`

```zig
fn hashBytes(bytes: []const u8) u64
```

Effects: `effects(.noalloc, .noio)`

## Function `main`

```zig
pub fn main() void
```

# Zig++ API: `examples/owned_buffer.zpp`

## Owned Struct `Buffer`

## Function `main`

```zig
pub fn main() !void
```

# Zig++ API: `examples/where_constraints.zpp`

## Trait `Ord`

Methods:
- `fn rank(self) u32;`

## Function `min`

```zig
fn min(comptime T: type, a: T, b: T) T
```

Bounds:
- `where T: Ord`

## Function `main`

```zig
pub fn main() void
```

