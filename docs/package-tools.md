# Package Tools

Zig++ includes small package-level tools for auditing source files, generating
API notes, producing JSON Lines API manifests, checking source formatting, and
checking API compatibility. These tools are intentionally conservative. They are
designed to make source costs and public surface changes visible in CI before
the language is stable.

## Tool Layers

The prototype has three related tools:

- `zpp-doc`: generates Markdown API notes for one `.zpp` source file
- `zpp-api`: generates and checks JSON Lines API manifests for one or more
  `.zpp` source files
- `zpp-package`: reads a package manifest and runs audit, docs, API generation,
  format checks, docs drift checks, or API compatibility checks across the
  package source lists

Use `zpp-package` for repository CI. Use `zpp-doc` and `zpp-api` directly when
iterating on one file or debugging manifest output.

## Package Manifest

The package manifest is JSON. The current repository uses
`zpp-package.json`:

```json
{
  "name": "zigpp-examples",
  "version": "0.1.0",
  "api_output": "docs/zigpp-examples.api.jsonl",
  "api_baseline": "docs/zigpp-examples.api.jsonl",
  "docs_output": "docs/zigpp-examples-api.md",
  "sources": [
    "examples/contracts.zpp",
    "examples/derive_user.zpp",
    "examples/effects_visibility.zpp",
    "examples/hello_trait.zpp",
    "examples/noalloc_hash.zpp",
    "examples/owned_buffer.zpp",
    "examples/where_constraints.zpp"
  ],
  "format_sources": [
    "examples/contracts.zpp",
    "examples/derive_user.zpp",
    "examples/dyn_plugin.zpp",
    "tests/diagnostics/missing_deinit.zpp",
    "tests/lowering/using.zpp"
  ]
}
```

Fields:

| Field | Required | Meaning |
| --- | --- | --- |
| `name` | yes | Package name used in command output |
| `version` | no | Informational package version |
| `sources` | yes | Ordered list of `.zpp` files to audit and document |
| `format_sources` | no | Ordered list of `.zpp` files checked by `--fmt-check`; defaults to `sources` |
| `api_output` | no | Default output path for `--api` |
| `api_baseline` | no | Default baseline path for API checks |
| `docs_output` | no | Default output path for `--doc` and baseline path for `--doc-check` |

Unknown JSON fields are ignored by the current parser, so experiments can add
metadata without breaking the prototype tools.

## Package Commands

Audit all package sources:

```sh
zig build package-zpp -- zpp-package.json --audit
```

Generate the package API manifest to the manifest's `api_output`:

```sh
zig build package-zpp -- zpp-package.json --api
```

Generate package docs to the manifest's `docs_output`:

```sh
zig build package-zpp -- zpp-package.json --doc
```

Require all package format sources to match `zpp-fmt` output:

```sh
zig build package-zpp -- zpp-package.json --fmt-check
```

Require generated package docs to match the manifest's `docs_output`:

```sh
zig build package-zpp -- zpp-package.json --doc-check
```

Require the generated API manifest to exactly match the baseline:

```sh
zig build package-zpp -- zpp-package.json --api-check
```

Allow additive API changes but fail when a baseline line disappears:

```sh
zig build package-zpp -- zpp-package.json --api-check-compatible
```

Override output or baseline paths explicitly:

```sh
zig build package-zpp -- zpp-package.json --api -o /tmp/package.api.jsonl
zig build package-zpp -- zpp-package.json --api-check /tmp/package.api.jsonl
zig build package-zpp -- zpp-package.json --doc-check /tmp/package.md
```

Treat warnings as failures during audit:

```sh
zig build package-zpp -- zpp-package.json --audit --deny-warnings
```

## API Manifest Format

API manifests are JSON Lines: each line is one JSON object. This keeps diffs
small and lets compatibility checks compare public declarations line by line.

Current entry kinds:

| Kind | Meaning |
| --- | --- |
| `trait` | Top-level `trait Name` declaration |
| `trait_method` | Method declared inside a trait |
| `owned_struct` | Top-level `owned struct Name` declaration |
| `function` | Top-level `pub fn` declaration |

Example:

```json
{"kind":"trait","path":"examples/hello_trait.zpp","name":"Writer"}
{"kind":"trait_method","path":"examples/hello_trait.zpp","owner":"Writer","name":"write","signature":"fn write(self, bytes: []const u8) !usize;"}
{"kind":"owned_struct","path":"examples/hello_trait.zpp","name":"FileWriter"}
{"kind":"function","path":"examples/hello_trait.zpp","name":"main","signature":"pub fn main() !void","effects":"","bounds":[],"contracts":[]}
```

Function entries include:

- `name`: function name
- `signature`: source signature line
- `effects`: adjacent `effects(...)` line when present
- `bounds`: adjacent `where ...` lines
- `contracts`: adjacent `requires(...)`, `invariant(...)`, and `ensures(...)`
  lines

Only top-level `pub fn` declarations are exported as function entries. Private
helpers are omitted from the API manifest.

## Compatibility Modes

`--api-check` compares the generated manifest with the baseline after trimming
trailing whitespace. Any changed, added, removed, or reordered line fails.
When it fails, `zpp-package` prints the first differing line with the baseline
value as `expected` and the generated value as `actual`.

Use it when the baseline is intended to be exact:

```sh
zig build package-zpp -- zpp-package.json --api-check
```

`--api-check-compatible` checks only that every non-empty baseline line still
exists in the generated manifest. Added lines are allowed. When compatibility
fails, the output includes the first missing baseline line.

Use it when additive public API changes are acceptable:

```sh
zig build package-zpp -- zpp-package.json --api-check-compatible
```

Because compatibility is currently line-based, changing a signature, effect
annotation, bound, contract, path, or declaration order can change the manifest.
That strictness is useful for review, but it is not a final semantic
compatibility model.

## Documentation Output

`zpp-doc` and `zpp-package --doc` generate Markdown API notes. `zpp-package
--doc-check` compares generated package docs with the checked-in baseline. The
output is intended for quick review, not polished reference documentation. Drift
failures include the first differing Markdown line so CI logs point at the
changed section before opening a local diff.

The generated docs currently include:

- traits and trait methods
- owned structs
- functions
- function effects
- trait bounds
- contracts

The repository checks in generated example docs at
`docs/zigpp-examples-api.md` so changes to doc extraction are visible in diffs.

## CI Policy

The current GitHub Actions workflow runs:

```sh
zig build ci
```

This policy keeps six surfaces under review:

- unit and behavior tests
- `.zpp` source formatting
- `.zpp` lowering fixtures
- generated Zig compile checks
- package diagnostics, API baseline drift, and docs baseline drift
- manifest-driven `.zpp` source formatting

The `ci` build step expands to `zig build test`, formatter checks, package
audit, package API baseline checks, and package docs baseline checks. `zig build
test` already includes fixture and compile-fixture checks.

When changing public examples or API extraction, regenerate the checked-in
package outputs and commit them with the source change:

```sh
zig build package-zpp -- zpp-package.json --api
zig build package-zpp -- zpp-package.json --doc
```

## Current Limits

- manifest extraction is source-pattern based
- the API manifest is line-based, not semantic
- only top-level public functions are included as function API entries
- compatibility checks do not classify changes beyond exact match or baseline
  line removal
- generated docs are intentionally minimal
