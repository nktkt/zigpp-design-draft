# Architecture

This repository is a prototype Zig++ frontend and toolchain scaffold. The
implementation is intentionally small: `.zpp` source is parsed into a thin
source wrapper, checked by local diagnostics, lowered to readable Zig, and then
compiled or inspected by ordinary Zig tooling.

## Data Flow

The main frontend path is:

```text
.zpp source
   -> parser.parse
   -> sema.checkSource
   -> lower_to_zig.lower
   -> generated .zig
   -> zig compiler or stdout/file output
```

`src/lib.zig` is the public module surface for this path:

```zig
pub fn lowerSource(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    const tree = try parser.parse(allocator, source);
    defer tree.deinit(allocator);
    return lower_to_zig.lower(allocator, tree);
}
```

The prototype currently keeps parsing lightweight. Most interesting behavior is
in diagnostics and lowering rather than a full AST or type system.

## Core Modules

`src/compiler/ast.zig`

Defines the current source representation consumed by lowering. It is not yet a
full Zig++ AST.

`src/compiler/parser.zig`

Builds the current source wrapper. This is the intended place to grow a
structured parser during the frontend hardening phase.

`src/compiler/sema.zig`

Runs local diagnostics over raw source:

- must-cleanup checks for `own var`
- use-after-move checks
- double-cleanup checks
- effect visibility checks
- negative effect checks such as `.noalloc` and `.nounsafe`

The current implementation is intentionally source-pattern based. It is a
guardrail for examples and CI, not a final semantic analyzer.

`src/compiler/lower_to_zig.zig`

Rewrites implemented Zig++ syntax to explicit Zig:

- `using` to `defer value.deinit()`
- `owned struct` to ordinary Zig `const Name = struct`
- `trait` to `VTable`, `Dyn`, and `require`
- `impl Trait` to `anytype` plus `Trait.require`
- `dyn Trait` to `Trait.Dyn`
- `where` to comptime trait requirements
- contracts to explicit runtime checks
- `derive` to visible `zpp.derive.*(@This())` declarations

See [lowering-rules.md](lowering-rules.md) for the public lowering contract.

`src/compiler/diagnostics.zig`

Defines diagnostic severity, source location, message formatting, and the
diagnostic bag used by `sema`.

## Runtime Library Stubs

`src/lib/` contains experimental support modules that model the intended
standard-library shape:

- `traits.zig`
- `owned.zig`
- `contracts.zig`
- `derive.zig`
- `dyn.zig`
- `async.zig`
- `testing.zig`

These modules are not a replacement for Zig `std`. They are scaffolding for
allocator-first, visible-cost APIs that examples can import while the language
layer evolves.

## CLI Tools

The build installs these executables:

| Tool | Source | Purpose |
| --- | --- | --- |
| `zpp` | `src/tools/zpp.zig` | Run diagnostics and lower one `.zpp` file |
| `zpp-api` | `src/tools/zpp_api.zig` | Generate or check JSON Lines API manifests |
| `zpp-audit` | `src/tools/zpp_audit.zig` | Run diagnostics across multiple files |
| `zpp-package` | `src/tools/zpp_package.zig` | Run package manifest commands |
| `zpp-fmt` | `src/tools/zpp_fmt.zig` | Conservative formatter experiment |
| `zpp-doc` | `src/tools/zpp_doc.zig` | Generate Markdown API notes |
| `zpp-lsp` | `src/tools/zpp_lsp.zig` | Minimal stdio LSP diagnostics server |
| `zpp-migrate` | `src/tools/zpp_migrate.zig` | Conservative Zig-to-Zig++ migration helper |

The tool layer should stay thin. Shared language behavior belongs in
`src/compiler/` or `src/lib/`, not duplicated across tools.

## Build Steps

`build.zig` wires the module, tools, tests, and fixture commands.

Common steps:

```sh
zig build
zig build test
zig build ci
zig build run -- examples/hello_trait.zpp -o /tmp/hello_trait.zig
zig build fixture-test
zig build compile-fixtures
```

Tool-specific steps:

```sh
zig build audit-zpp -- examples/hello_trait.zpp
zig build api-zpp -- examples/hello_trait.zpp
zig build doc-zpp -- examples/hello_trait.zpp
zig build package-zpp -- zpp-package.json --audit
zig build package-zpp -- zpp-package.json --fmt
zig build package-zpp -- zpp-package.json --fmt-check
zig build package-zpp -- zpp-package.json --refresh
zig build package-zpp -- zpp-package.json --check
```

`zig build test` runs:

- unit tests for `src/lib.zig`
- unit tests for each tool with tests
- fixture lowering tests
- generated Zig compile fixture checks

`zig build ci` runs `zig build test` plus `zpp-package --check`. It is the local
equivalent of the GitHub Actions workflow.

## Fixtures and Examples

`examples/` contains positive examples for public-facing syntax and tooling.
These files are intended to be readable by users.

`tests/diagnostics/` contains source snippets that should trigger diagnostic
behavior.

`tests/lowering/` contains lowering fixtures.

`tests/compile/` contains generated Zig compile checks.

The fixture tools live in:

- `src/tools/zpp_fixture_test.zig`
- `src/tools/zpp_compile_fixtures.zig`

## Generated Docs and API Artifacts

The repository checks in generated package artifacts:

- `docs/zigpp-examples.api.jsonl`
- `docs/zigpp-examples-api.md`

They are generated through:

```sh
zig build package-zpp -- zpp-package.json --refresh
```

CI checks the API baseline with:

```sh
zig build package-zpp -- zpp-package.json --check
```

This makes formatter drift, diagnostics, public API extraction drift, and docs
drift visible in pull requests.

## Design Boundaries

The current architecture deliberately avoids:

- replacing the Zig compiler
- adding hidden destructors or implicit cleanup
- adding exceptions
- introducing macro expansion as a separate language model
- hiding dynamic dispatch behind ordinary method syntax

The compiler layer may become more structured, but the generated Zig should
remain readable enough to review directly.

## Near-Term Refactor Direction

The next architectural step is to replace line-oriented parsing with structured
syntax while preserving the existing external behavior:

1. keep current examples and fixtures passing
2. introduce AST nodes for implemented syntax
3. move diagnostics from string scanning toward AST/sema checks
4. keep lowering output deterministic
5. keep tool behavior and package outputs stable unless the change is explicit
