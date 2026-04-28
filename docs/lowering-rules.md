# Lowering Rules

This document describes the current prototype lowering contract for `.zpp`
source. It is not a stable language specification yet. The purpose is to keep
the generated Zig shape explicit and reviewable while the parser and semantic
passes are still experimental.

The central rule is:

```text
Zig++ syntax may shorten common patterns, but it must not hide allocation,
cleanup, dispatch, unsafe behavior, or control flow.
```

## `using`

`using` is explicit scope cleanup. It lowers to Zig `defer` immediately after
the binding or at the current point in the scope.

Input:

```zig
using file = try File.open("log.txt");
try file.writeAll("hello\n");
```

Lowered Zig:

```zig
var file = try File.open("log.txt");
defer file.deinit();
try file.writeAll("hello\n");
```

Existing binding form:

```zig
using file;
```

Lowered Zig:

```zig
defer file.deinit();
```

Rules:

- cleanup only happens where `using` appears
- the cleanup call is always visible as `defer value.deinit()`
- there is no implicit destructor model

## `owned struct`

`owned struct` marks a type as participating in ownership diagnostics. The
runtime representation remains an ordinary Zig struct declaration.

Input:

```zig
owned struct Buffer {
    data: []u8,
}
```

Lowered Zig:

```zig
const Buffer = struct {
    data: []u8,
};
```

Rules:

- ownership is a diagnostic layer, not a runtime wrapper
- `deinit` remains an ordinary method
- resource cleanup remains explicit through `using` or direct `deinit`

## `own var` and `move`

`own var` lowers to a normal `var` declaration and enables ownership
diagnostics. `move` is removed during lowering and is used by diagnostics to
reject later use of the moved value.

Input:

```zig
own var buf = try Buffer.init(allocator, 4096);
using buf;

var moved = move buf;
```

Lowered Zig shape:

```zig
var buf = try Buffer.init(allocator, 4096);
defer buf.deinit();

var moved = buf;
```

Diagnostics currently target:

- owned value not cleaned up
- use after move
- cleanup after move
- double cleanup

Rules:

- `move` does not allocate or call user code
- the checker is intentionally conservative
- this is not a full borrow checker

## `trait`

A `trait` declaration lowers to a Zig struct containing:

- a `VTable` type for dynamic dispatch
- a `Dyn` carrier for explicit dynamic dispatch
- a `require(comptime T: type)` function for static conformance checks

Input:

```zig
trait Writer {
    fn write(self, bytes: []const u8) !usize;
}
```

Lowered Zig shape:

```zig
const Writer = struct {
    pub const VTable = struct {
        write: *const fn (*anyopaque, []const u8) anyerror!usize,
    };

    pub const Dyn = struct {
        ptr: *anyopaque,
        vtable: *const VTable,

        pub fn write(self: Dyn, bytes: []const u8) !usize {
            return self.vtable.write(self.ptr, bytes);
        }
    };

    pub fn require(comptime T: type) void {
        const U = target(T);
        if (!hasMethod(U, "write")) {
            @compileError("type does not implement Writer: missing method write");
        }
    }
};
```

The generated helper also strips pointer types before checking declarations, so
`Writer.require(@TypeOf(&value))` checks the pointed-to type.

Rules:

- static conformance is checked with `Trait.require(T)`
- dynamic dispatch is represented by an explicit `Trait.Dyn`
- the prototype checks method presence, not full signature compatibility yet

## `impl Trait`

`impl Trait` is static dispatch. It lowers to `anytype` and inserts a comptime
requirement at function entry.

Input:

```zig
fn emit(w: impl Writer, msg: []const u8) !void {
    _ = try w.write(msg);
}
```

Lowered Zig:

```zig
fn emit(w: anytype, msg: []const u8) !void {
    comptime Writer.require(@TypeOf(w));
    _ = try w.write(msg);
}
```

Rules:

- the call remains statically dispatched
- no vtable is introduced by `impl`
- the constraint is visible in generated Zig

## `dyn Trait`

`dyn Trait` is explicit dynamic dispatch. It lowers to `Trait.Dyn`.

Input:

```zig
fn render(plugin: dyn AudioPlugin, input: []const f32, output: []f32) void {
    plugin.process(input, output);
}
```

Lowered Zig:

```zig
fn render(plugin: AudioPlugin.Dyn, input: []const f32, output: []f32) void {
    plugin.process(input, output);
}
```

Rules:

- vtable dispatch only appears where `dyn` appears in source
- the dynamic carrier is a visible `ptr` plus `vtable`
- ordinary method syntax does not become virtual implicitly

## `where`

`where` clauses attach trait constraints to a function and lower to comptime
requirements at function entry. The original `where` line is preserved as a
comment in generated Zig.

Input:

```zig
fn min(comptime T: type, a: T, b: T) T
    where T: Ord
{
    if (a.rank() < b.rank()) return a;
    return b;
}
```

Lowered Zig shape:

```zig
fn min(comptime T: type, a: T, b: T) T
    // zpp: where T: Ord
{
    comptime Ord.require(T);
    if (a.rank() < b.rank()) return a;
    return b;
}
```

Rules:

- `where T: Trait` is a named static constraint
- multiple comma-separated bounds are accepted by the prototype
- public API semantics for structural versus nominal conformance are not stable
  yet

## Contracts

Contracts are lowered to explicit runtime checks in the generated Zig.

Input:

```zig
fn at(xs: []const u8, i: usize) u8
    requires(i < xs.len)
    invariant(xs.len > 0)
{
    return xs[i];
}
```

Lowered Zig shape:

```zig
fn at(xs: []const u8, i: usize) u8
{
    if (!(i < xs.len)) @panic("contract requires failed");
    if (!(xs.len > 0)) @panic("contract invariant failed");
    return xs[i];
}
```

`ensures` rewrites returns through a temporary result binding:

```zig
fn abs(x: i32) i32
    ensures(result >= 0)
{
    return if (x < 0) -x else x;
}
```

Lowered Zig shape:

```zig
fn abs(x: i32) i32
{
    const zpp_result_0 = if (x < 0) -x else x;
    if (!(zpp_result_0 >= 0)) @panic("contract ensures failed");
    return zpp_result_0;
}
```

Rules:

- `requires` and `invariant` run at function entry
- `ensures` checks explicit `return expr;` statements
- contract checks are visible control flow in generated Zig

## `effects(...)`

Effect declarations are currently diagnostic metadata. During lowering, the
effect line is preserved as a comment so the cost annotation remains visible in
generated Zig.

Input:

```zig
fn hashBytes(bytes: []const u8) u64
    effects(.noalloc, .noio)
{
    return bytes.len;
}
```

Lowered Zig shape:

```zig
fn hashBytes(bytes: []const u8) u64
    // zpp: effects(.noalloc, .noio)
{
    return bytes.len;
}
```

Diagnostics currently cover negative constraints such as:

- `.noalloc`
- `.noio`
- `.nothread`
- `.nodyn`
- `.nounsafe`
- `.nonblocking`

Rules:

- effects do not change runtime representation
- effect violations are reported by diagnostics and package audit tools
- effect inference is intentionally shallow in the current prototype

## `derive`

`derive` is not a macro system. It lowers to explicit comptime helper
declarations inside the struct.

Input:

```zig
const User = struct {
    id: u64,
    name: []const u8,
} derive(.{
    Json,
    Hash,
    Debug,
});
```

Lowered Zig:

```zig
const User = struct {
    id: u64,
    name: []const u8,

    pub const json = zpp.derive.Json(@This());
    pub const hash = zpp.derive.Hash(@This());
    pub const debug = zpp.derive.Debug(@This());
};
```

Rules:

- generated declarations are visible in the Zig output
- helper names lower to simple lower-camel identifiers
- derive behavior lives in ordinary `zpp.derive.*` helpers

## Prototype Limits

The current lowering implementation is intentionally small. Known limits:

- parsing is line-oriented
- trait checking verifies method presence, not complete signatures
- contract lowering only handles explicit `return expr;` forms
- effect checks are shallow and diagnostic-oriented
- ownership checking is affine and local, not a full lifetime system
- generated dynamic interface ABI is experimental

These limits are acceptable for the current scaffold, but they are also the
main targets for the frontend hardening phase in the roadmap.
