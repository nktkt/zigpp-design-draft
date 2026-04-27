# Zig++ Design Draft v0.1

This is an unofficial research draft for **Zig++**.

Zig++ is not "Zig with C++ features added until it becomes C++". It is a
language layer that keeps Zig's explicit systems-programming model while adding
visible high-level abstractions, ownership checks, interfaces, and package/API
tooling.

## 1. Core Rule

Zig++ must preserve the Zig properties that make costs readable:

- no hidden control flow
- no hidden allocation
- no hidden exceptions
- no hidden destructors
- no preprocessor or macro expansion model
- allocator-first library APIs

The central rule is:

```text
Every high-level construct must lower to readable Zig.
```

## 2. One-Sentence Concept

Zig++ is a Zig-compatible upper layer that keeps explicit low-level control but
adds C++-class abstraction, ownership, type constraints, dynamic interfaces, and
large-project support without inheriting C++'s implicit behavior.

## 3. Name and Command

```text
Language name: Zig++
Extension:     .zpp
Command:       zpp
Build path:    integrated through zig build
```

The command is not `zig++`, because Zig already uses `zig c++` for C++
compilation.

## 4. Architecture

The first implementation should be a frontend that lowers `.zpp` to `.zig`:

```text
.zpp source
   -> Zig++ parser
   -> Zig++ semantic analyzer
   -> lowering
   -> generated .zig
   -> zig compiler
```

## 5. Language Layers

### Layer 0: Zig Core

`.zpp` accepts ordinary Zig-like code. Existing `.zig` code stays Zig code.
`comptime` remains the central mechanism for generics and metaprogramming.

### Layer 1: Trait / Interface

```zig
trait Writer {
    fn write(self, bytes: []const u8) !usize;
}

fn dump(w: impl Writer, data: []const u8) !void {
    _ = try w.write(data);
}
```

`impl Writer` means static dispatch. `dyn Writer` means explicit dynamic
dispatch.

### Layer 2: Explicit RAII

```zig
using file = try File.open("log.txt");
try file.writeAll("hello\n");
```

Lowering:

```zig
var file = try File.open("log.txt");
defer file.deinit();
try file.writeAll("hello\n");
```

Cleanup is not hidden: it only appears where `using` appears.

### Layer 3: Ownership / Move

```zig
own var buf = try Buffer.init(allocator, 4096);
using buf;

var moved = move buf;
```

The MVP checker should detect:

- owned value not deinitialized
- use after move
- double deinit
- allocator mismatch

### Layer 4: Effect Visibility

```zig
fn parseJson(a: Allocator, input: []const u8) !Json
    effects(.alloc, .cpu)
{
    ...
}

fn checksum(input: []const u8) u64
    effects(.noalloc, .noio)
{
    ...
}
```

Initial effects can be lint-level checks:

```text
.alloc
.io
.blocking
.spawn
.dyn
.unsafe
```

### Layer 5: Contracts

```zig
fn at(comptime T: type, xs: []const T, i: usize) T
    requires(i < xs.len)
{
    return xs[i];
}
```

Contracts are runtime checks in Debug and ReleaseSafe, optimization hints in
ReleaseFast, and compile errors when the compiler can decide them at comptime.

### Layer 6: Derive Without Macro

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

Derive must lower to visible Zig `comptime` calls rather than opaque macro
expansion.

## 6. Standard Library Shape

Zig++ should provide an upper library layer instead of replacing Zig `std`:

```text
zpp.trait      Reader, Writer, Iterator, Collection
zpp.owned      Owned(T), Borrow(T), ArenaScope, DeinitGuard
zpp.container  Vec(T), SmallVec(T, N), String, Map(K, V), Set(T)
zpp.io         dyn Reader, dyn Writer, BufferedReader, BufferedWriter
zpp.async      Task, TaskGroup, Future, CancellationToken
zpp.contract   requires, ensures, invariant
zpp.testing    property tests, fuzz harness, snapshot tests
zpp.ffi        extern interface, plugin ABI, C bridge
```

All allocation-capable APIs are allocator-first.

## 7. C++ Mapping

| C++ | Zig++ |
| --- | --- |
| `class` | `struct` + `impl` + `trait` |
| constructor | explicit `init()` |
| destructor | explicit `using` / `deinit()` |
| template | `comptime` + `trait` |
| concept | `trait` / `where` |
| virtual method | `dyn Trait` |
| exception | Zig error union |
| RAII | explicit RAII |
| STL container | allocator-first container |
| macro | `comptime` derive |
| inheritance | composition + trait |

## 8. MVP Scope

The first useful Zig++ should implement only:

```text
1. trait
2. impl / dyn
3. using
4. must-deinit checker
```

This addresses generic constraints, deinit omissions, explicit interface design,
and better diagnostics without introducing hidden costs.

## 9. Success Conditions

```text
Higher-level than Zig
More explicit than C++
Lighter than Rust
Safer than C
```

In practice:

- generated Zig is readable
- allocator arguments remain visible
- deinit remains visible
- dynamic dispatch remains visible through `dyn`
- unsafe remains visible
- `comptime` remains central

## 10. Definition

Zig++ is a large-project Zig layer that preserves Zig's visible low-level model
while adding trait interfaces, explicit RAII, ownership analysis, effect
visibility, dynamic interfaces, and package API management.
