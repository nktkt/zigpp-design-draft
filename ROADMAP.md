# Roadmap

Zig++ is currently a research scaffold. The roadmap is organized around one
constraint: every higher-level feature must lower to readable Zig while keeping
allocation, cleanup, dispatch, unsafe behavior, and control flow visible.

## Current Snapshot

The prototype already covers the intended MVP shape:

- `.zpp` to `.zig` lowering through `zpp`
- `trait` declarations with generated `require`, `VTable`, and `Dyn` shapes
- `impl Trait` static-dispatch checks
- explicit `dyn Trait` lowering
- explicit cleanup with `using`
- `own var` and `move` diagnostics for basic affine ownership checks
- effect visibility diagnostics for allocation, I/O, thread/task spawning,
  dynamic dispatch, unsafe behavior, and blocking behavior
- lightweight contracts and macro-free `derive` lowering
- package audit, docs, API manifest, and API compatibility tools
- CI over tests, fixtures, generated Zig compilation, package audit, and API
  baseline checks

## Phase 1: Frontend Hardening

Goal: make the existing lowering and diagnostics predictable enough for wider
experimentation.

- replace line-oriented parsing with a structured parser for the implemented
  syntax
- move more checks out of string scanning and into AST or semantic passes
- improve diagnostics with source spans and stable diagnostic codes
- keep generated Zig deterministic for fixture tests
- add regression fixtures for every accepted lowering form
- document the exact lowering rules for `trait`, `impl`, `dyn`, `using`,
  `own var`, `move`, `effects`, contracts, and `derive`

Exit criteria:

- fixture tests cover all MVP syntax
- diagnostics are stable enough to snapshot
- generated Zig can be reviewed without knowing the frontend internals

## Phase 2: Trait Semantics

Goal: make `trait`, `impl Trait`, `dyn Trait`, and `where` constraints useful
for larger APIs.

- define structural trait checking rules
- define nominal implementation rules for public APIs
- add sealed traits for interfaces that require explicit implementation
- improve method signature compatibility checks
- generate clearer errors for missing methods and incompatible signatures
- document static dispatch versus dynamic dispatch lowering

Exit criteria:

- a package can publish trait-constrained APIs with predictable diagnostics
- dynamic interface layout is documented for prototype use
- examples include both structural and nominal-style patterns

## Phase 3: Ownership and Cleanup Analysis

Goal: reduce resource leaks and double cleanup while preserving Zig's explicit
`defer` model.

- track `own var` values through moves, scopes, and explicit `deinit`
- detect missing cleanup on all local owned paths the prototype can model
- detect use after move with clearer source locations
- detect cleanup after move and double cleanup consistently
- prototype allocator pairing checks for allocator-first containers
- document where the checker is intentionally conservative

Exit criteria:

- ownership diagnostics are precise enough to use in examples and CI
- every `using` lowering remains visible as `defer value.deinit()`
- no hidden destructor or implicit cleanup model is introduced

## Phase 4: Package, API, and Documentation Tools

Goal: make Zig++ package evolution auditable before adding more language
surface.

- expand `zpp-package` manifest validation
- stabilize JSON Lines API manifest fields
- make compatibility checks distinguish breaking, additive, and informational
  changes
- generate docs for traits, effects, contracts, and dynamic interfaces
- add examples that publish a small package-level API

Exit criteria:

- package API output can be reviewed in pull requests
- compatibility checks catch renamed or removed public declarations
- generated docs are useful without reading the lowering source

## Phase 5: Effect Visibility

Goal: make visible costs enforceable enough for CI use.

- infer local effects from calls to known allocation, I/O, unsafe, dynamic
  dispatch, spawn, and blocking operations
- support negative constraints such as `.noalloc`, `.noio`, `.nounsafe`, and
  `.nodyn`
- make effect diagnostics composable across package boundaries
- expose effect information in docs and API manifests

Exit criteria:

- packages can fail CI on forbidden effects
- public APIs can document visible cost boundaries
- false positives are documented and narrow enough for prototype users

## Phase 6: Runtime Library Experiments

Goal: validate the language layer against practical library code.

- allocator-first `Vec`, `SmallVec`, `String`, `Map`, and `Set` experiments
- `Reader` and `Writer` traits with static and dynamic dispatch examples
- `ArenaScope` and `DeinitGuard` ownership helpers
- structured concurrency experiments that keep `spawn`, `cancel`, and
  allocator use visible
- FFI and plugin ABI sketches using `extern interface`

Exit criteria:

- examples show real resource ownership, not only syntax demos
- containers and I/O helpers preserve allocator visibility
- dynamic and external interfaces have explicit ABI documentation

## Phase 7: Stabilization Criteria

Zig++ should not claim a stable release until these are true:

- syntax and lowering rules are specified
- generated Zig is deterministic and readable
- trait and dynamic interface behavior is documented
- ownership and cleanup diagnostics have conformance tests
- package API compatibility checks are stable enough for CI
- formatter and LSP behavior are predictable for implemented syntax
- at least one non-trivial example package exercises traits, ownership,
  effects, docs, and API checks together

## Non-Goals

These remain outside the roadmap unless the design changes substantially:

- hidden constructors or destructors
- exceptions
- default heap allocation
- macro expansion as a separate language
- implicit virtual dispatch
- inheritance as the primary reuse model
- a Rust-style full borrow checker in the MVP
