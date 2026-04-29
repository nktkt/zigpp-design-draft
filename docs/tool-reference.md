# Tool Reference

This document is a compact reference for the Zig++ prototype command-line
tools. For package-level API and documentation workflows, also read
[package-tools.md](package-tools.md).

Build the tools with:

```sh
zig build
```

Installed tools are written under `zig-out/bin/`.

## Summary

| Tool | Purpose |
| --- | --- |
| `zpp` | Check and lower one `.zpp` file to Zig |
| `zpp-audit` | Run diagnostics over multiple `.zpp` files |
| `zpp-api` | Generate or check JSON Lines API manifests |
| `zpp-package` | Run package manifest commands |
| `zpp-doc` | Generate Markdown API notes for one source file |
| `zpp-fmt` | Conservatively format `.zpp` files in place |
| `zpp-lsp` | Minimal stdio LSP diagnostics server |
| `zpp-migrate` | Rewrite adjacent Zig `defer deinit` patterns to `using` |

## Exit Behavior

Most tools use this policy:

- `0`: success
- `1`: requested check failed
- `2`: usage error or invalid command-line option

Warnings do not fail by default. Tools that accept `--deny-warnings` or
`-Werror` treat warnings as failures.

## `zpp`

Usage:

```text
zpp <input.zpp> [-o output.zig] [--check] [--deny-warnings]
```

Purpose:

- runs diagnostics for one source file
- lowers `.zpp` to Zig unless `--check` is used
- writes to stdout by default, or to `-o output.zig`
- prints diagnostics as `path:line:column: severity[code]: message`

Examples:

```sh
./zig-out/bin/zpp examples/hello_trait.zpp
./zig-out/bin/zpp examples/hello_trait.zpp -o /tmp/hello_trait.zig
./zig-out/bin/zpp tests/diagnostics/effect_unsafe.zpp --check
./zig-out/bin/zpp tests/diagnostics/effect_unsafe.zpp --check --deny-warnings
```

Failure policy:

- errors fail
- warnings fail only with `--deny-warnings` or `-Werror`
- `--check` never writes lowered output

## `zpp-audit`

Usage:

```text
zpp-audit [--deny-warnings] <file.zpp>...
```

Purpose:

- runs the same diagnostics as `zpp --check`
- accepts multiple source files
- prints per-file diagnostics and an aggregate count

Example:

```sh
./zig-out/bin/zpp-audit examples/hello_trait.zpp examples/noalloc_hash.zpp
./zig-out/bin/zpp-audit --deny-warnings examples/effects_visibility.zpp
```

Failure policy:

- any error fails
- warnings fail only with `--deny-warnings` or `-Werror`

## `zpp-api`

Usage:

```text
zpp-api <input.zpp>... [-o output.jsonl] [--check baseline.jsonl] [--check-compatible baseline.jsonl]
```

Purpose:

- generates a JSON Lines API manifest
- can require exact manifest equality with `--check`
- can allow additive changes with `--check-compatible`

Examples:

```sh
./zig-out/bin/zpp-api examples/hello_trait.zpp
./zig-out/bin/zpp-api examples/hello_trait.zpp examples/contracts.zpp -o /tmp/package.api.jsonl
./zig-out/bin/zpp-api examples/hello_trait.zpp --check /tmp/package.api.jsonl
./zig-out/bin/zpp-api examples/hello_trait.zpp --check-compatible /tmp/package.api.jsonl
```

Failure policy:

- `--check` fails on any changed, added, removed, or reordered line
- `--check-compatible` fails when a baseline line is missing
- `--check` and `--check-compatible` cannot be used together

## `zpp-package`

Usage:

```text
zpp-package <package.json> (--validate | --audit | --fmt | --fmt-check | --refresh | --check | --api [-o output.jsonl] | --doc [-o output.md] | --doc-check [baseline.md] | --api-check [baseline.jsonl] | --api-check-compatible [baseline.jsonl]) [--deny-warnings]
```

Purpose:

- reads a package manifest
- validates manifest source paths
- audits all package sources
- formats package format sources
- checks package format sources
- refreshes generated package artifacts
- runs the package CI checks
- generates package API manifests and docs
- checks generated package docs against a baseline
- checks package API baselines

Examples:

```sh
zig build package-zpp -- zpp-package.json --validate
zig build package-zpp -- zpp-package.json --audit
zig build package-zpp -- zpp-package.json --fmt
zig build package-zpp -- zpp-package.json --fmt-check
zig build package-zpp -- zpp-package.json --refresh
zig build package-zpp -- zpp-package.json --check
zig build package-zpp -- zpp-package.json --api
zig build package-zpp -- zpp-package.json --doc
zig build package-zpp -- zpp-package.json --doc-check
zig build package-zpp -- zpp-package.json --api-check
zig build package-zpp -- zpp-package.json --api-check-compatible
```

Failure policy:

- choose exactly one package command
- validation fails on missing source files or duplicate source entries
- audit errors fail
- audit warnings fail only with `--deny-warnings` or `-Werror`
- `--fmt` writes formatted output for changed `format_sources`
- format checks fail when any `format_sources` entry would change
- `--refresh` writes formatted sources plus configured API and docs outputs
- `--check` fails on manifest validation, formatter drift, audit failures, API
  drift, or docs drift
- API checks fail when their manifest policy is violated
- `--doc-check` fails when generated Markdown differs from the baseline
- exact API and docs drift failures print the first differing line as
  `expected` versus `actual`
- compatible API drift failures print the first missing baseline line

## `zpp-doc`

Usage:

```text
zpp-doc <input.zpp> [-o output.md]
```

Purpose:

- generates Markdown API notes from one source file
- writes to stdout by default, or to `-o output.md`

Example:

```sh
./zig-out/bin/zpp-doc examples/hello_trait.zpp
./zig-out/bin/zpp-doc examples/hello_trait.zpp -o /tmp/hello_trait.md
```

The generated notes are intentionally minimal. They are for review and
prototype documentation, not final reference docs.

## `zpp-fmt`

Usage:

```text
zpp-fmt [--check] <file.zpp>...
```

Purpose:

- formats files in place
- trims trailing whitespace
- collapses repeated blank lines
- reports formatting drift without writing files when `--check` is used

Example:

```sh
./zig-out/bin/zpp-fmt examples/hello_trait.zpp examples/noalloc_hash.zpp
./zig-out/bin/zpp-fmt --check examples/hello_trait.zpp examples/noalloc_hash.zpp
```

Failure policy:

- normal mode writes changes in place
- `--check` prints `zpp-fmt: would change <path>` and exits `1` when a file
  would be rewritten
- unknown options fail with usage error

Current limits:

- formatting is conservative and line-oriented
- it does not parse or reflow Zig++ syntax

## `zpp-lsp`

Usage:

```text
zpp-lsp
```

Purpose:

- runs a minimal Language Server Protocol server over stdio
- responds to `initialize`, `shutdown`, and `exit`
- publishes diagnostics on `textDocument/didOpen` and `textDocument/didChange`

Current capabilities:

- full-document sync
- diagnostics from `zpp.sema.checkSource`

Current limits:

- no completion, hover, formatting, rename, or go-to-definition support
- no workspace indexing
- no persistent file cache

## `zpp-migrate`

Usage:

```text
zpp-migrate [--check] <file.zig|file.zpp>...
```

Purpose:

- conservatively rewrites adjacent Zig cleanup patterns to Zig++ `using`

Recognized pattern:

```zig
var name = expr;
defer name.deinit();
```

Output:

```zig
using name = expr;
```

Examples:

```sh
./zig-out/bin/zpp-migrate src/example.zig
./zig-out/bin/zpp-migrate --check src/example.zig
```

Failure policy:

- normal mode writes changes in place
- `--check` prints `zpp-migrate: would change <path>` and exits `1` when a file
  would be rewritten
- unknown options fail with usage error

Current limits:

- only adjacent `var` plus `defer name.deinit()` is migrated
- comments inside the initializer are not migrated
- non-adjacent cleanup patterns are intentionally ignored

## Fixture Runners

Two internal executables are wired into build steps rather than installed as
public user tools:

- `zpp-fixture-test`
- `zpp-compile-fixtures`

Use them through:

```sh
zig build fixture-test
zig build compile-fixtures
```

`zig build test` depends on both fixture steps.

## Recommended Workflows

Developing language lowering:

```sh
zig build test
zig build fixture-test
zig build compile-fixtures
```

Changing diagnostics:

```sh
zig build test
zig build package-zpp -- zpp-package.json --audit
```

Changing public examples, formatting, or API extraction:

```sh
zig build package-zpp -- zpp-package.json --fmt
zig build package-zpp -- zpp-package.json --fmt-check
zig build package-zpp -- zpp-package.json --refresh
zig build package-zpp -- zpp-package.json --check
```

Checking repository CI locally:

```sh
zig build ci
```
