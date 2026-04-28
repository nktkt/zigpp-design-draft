# Zig++ Design Draft v0.1

[![CI](https://github.com/nktkt/zigpp-design-draft/actions/workflows/ci.yml/badge.svg)](https://github.com/nktkt/zigpp-design-draft/actions/workflows/ci.yml)

This repository is an experimental research scaffold for **Zig++**, a visible
high-level language layer over Zig.

Zig++ is not a fork of Zig, not an official Zig project, and not an attempt to
turn Zig into C++. The goal is to explore what higher-level abstractions could
look like if they preserve Zig's core discipline:

```text
visible abstraction
visible ownership
visible allocation
visible dispatch
visible unsafe
```

The current implementation is a small `.zpp` to `.zig` frontend plus supporting
tools. Generated Zig is intended to stay readable.

## Design Goal

Zig++ experiments with these ideas:

- named `trait` declarations for explicit generic constraints
- `impl Trait` for static dispatch
- `dyn Trait` for visible dynamic dispatch
- `using` for explicit scope cleanup
- `own var` and `move` diagnostics for affine ownership patterns
- `effects(...)` visibility checks for allocation, I/O, unsafe, dynamic
  dispatch, spawning, and blocking behavior
- lightweight `requires`, `invariant`, and `ensures` contracts
- `derive(.{ ... })` without macros, lowered to explicit comptime helpers
- package-level audit, API manifest, compatibility checks, and docs generation

## Current MVP

Implemented language lowering:

- `using name = expr;` lowers to `var name = expr; defer name.deinit();`
- `using name;` lowers to `defer name.deinit();`
- `owned struct Name { ... }` lowers to `const Name = struct { ... }`
- `trait Name { ... }` lowers to a Zig struct with `require`, `VTable`, and
  `Dyn`
- `impl Trait` lowers to `anytype` plus a generated
  `Trait.require(@TypeOf(param))` check
- `where T: Trait` lowers to `comptime Trait.require(T);`
- `dyn Trait` lowers to explicit `Trait.Dyn`
- `derive(.{ Debug, Hash, Json })` lowers to explicit
  `zpp.derive.*(@This())` declarations

Implemented diagnostics:

- missing cleanup for `own var`
- use after `move`
- double `deinit`
- cleanup after move
- effect visibility warnings
- negative effect constraints such as `.noalloc`, `.noio`, `.nothread`,
  `.nodyn`, `.nounsafe`, and `.nonblocking`

This is deliberately small. It proves the lowering shape before adding a real
parser, full semantic analysis, stable ABI rules, or a production-grade
formatter/LSP.

## Tools

The build installs these tools:

- `zpp`: lower `.zpp` to Zig and run diagnostics
- `zpp-fmt`: conservative formatter for `.zpp` files
- `zpp-doc`: single-file Markdown API docs
- `zpp-api`: JSON Lines public API manifest and compatibility checks
- `zpp-audit`: multi-file diagnostic audit
- `zpp-package`: package manifest commands for audit, API, compatibility, and docs
- `zpp-lsp`: minimal LSP server with diagnostics
- `zpp-migrate`: conservative Zig-to-Zig++ cleanup migration helper

## Quick Start

The local toolchain used for this scaffold is Zig 0.15.2.

```sh
zig build
zig build test
zig build ci
zig build run -- examples/hello_trait.zpp -o /tmp/hello_trait.zig
```

Run diagnostics:

```sh
./zig-out/bin/zpp tests/diagnostics/effect_unsafe.zpp --check
./zig-out/bin/zpp tests/diagnostics/effect_unsafe.zpp --check --deny-warnings
```

Generate docs and API manifests:

```sh
zig build doc-zpp -- examples/hello_trait.zpp
zig build api-zpp -- examples/hello_trait.zpp examples/contracts.zpp -o /tmp/package.api.jsonl
zig build api-zpp -- examples/hello_trait.zpp examples/contracts.zpp --check-compatible /tmp/package.api.jsonl
```

Use the package manifest:

```sh
zig build package-zpp -- zpp-package.json --audit
zig build package-zpp -- zpp-package.json --api
zig build package-zpp -- zpp-package.json --doc
zig build package-zpp -- zpp-package.json --api-check-compatible
```

Run fixture checks:

```sh
zig build fixture-test
zig build compile-fixtures
```

## Examples

- [hello_trait.zpp](examples/hello_trait.zpp): trait, `impl Trait`, and `using`
- [dyn_plugin.zpp](examples/dyn_plugin.zpp): explicit dynamic interface
- [owned_buffer.zpp](examples/owned_buffer.zpp): ownership and cleanup
- [noalloc_hash.zpp](examples/noalloc_hash.zpp): `.noalloc` and `.noio`
- [contracts.zpp](examples/contracts.zpp): `requires`, `invariant`, `ensures`
- [derive_user.zpp](examples/derive_user.zpp): macro-free `derive`
- [effects_visibility.zpp](examples/effects_visibility.zpp): visible effects
- [where_constraints.zpp](examples/where_constraints.zpp): `where T: Trait`

## Project Layout

```text
src/
  compiler/
    ast.zig
    diagnostics.zig
    lower_to_zig.zig
    parser.zig
    sema.zig
  lib/
    contracts.zig
    derive.zig
    dyn.zig
    owned.zig
    testing.zig
    traits.zig
  tools/
    zpp.zig
    zpp_api.zig
    zpp_audit.zig
    zpp_doc.zig
    zpp_fmt.zig
    zpp_lsp.zig
    zpp_migrate.zig
    zpp_package.zig
examples/
docs/
tests/
```

## Documentation

The documentation index is [docs/README.md](docs/README.md). It links to the
design draft, lowering rules, diagnostics, package tooling, architecture notes,
and generated example API docs.

## Roadmap

The implementation roadmap is tracked in [ROADMAP.md](ROADMAP.md).

## Contributing

This project is intentionally experimental. Contributions should keep the
central rule intact: generated Zig must stay readable, and high-level features
must not hide allocation, cleanup, dispatch, unsafe operations, or control flow.

See [CONTRIBUTING.md](CONTRIBUTING.md) for the local checks and design rules.

## Status

This repository is a prototype and design experiment. Syntax, diagnostics,
lowering rules, and tool behavior are all expected to change.

## License

MIT. See [LICENSE](LICENSE).
