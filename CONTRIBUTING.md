# Contributing

Zig++ is a design draft and prototype frontend, not a stable language. Changes
are welcome when they make the experiment clearer, more testable, or more
faithful to Zig's explicit programming model.

## Design Rules

- Keep generated Zig readable.
- Do not introduce hidden allocation.
- Do not introduce hidden cleanup or destructors.
- Do not introduce exceptions or hidden control flow.
- Keep dynamic dispatch visible at the source level with `dyn`.
- Keep allocator ownership visible in APIs and examples.
- Prefer small lowering rules that can be explained directly in Zig.

## Local Checks

Run these before publishing changes:

```sh
zig build test
zig build fixture-test
zig build compile-fixtures
zig build package-zpp -- zpp-package.json --audit
zig build package-zpp -- zpp-package.json --api-check
```

`zig build test` already covers the main unit tests and fixture checks. The
extra commands above are listed separately because they mirror the CI workflow
and make package-level regressions easier to isolate.

## Issues and Pull Requests

Use the GitHub issue templates when reporting bugs or proposing language
changes. Good reports include the `.zpp` input, the generated Zig shape when
relevant, and the exact command that exposes the problem.

Pull requests should keep the diff focused. Include tests for behavior changes,
and call out any intentional syntax, diagnostic, or generated API changes in
the PR description.

## Adding Language Features

New syntax should include:

- a short design note in the relevant docs or README section
- a lowering example showing the generated Zig shape
- at least one positive example in `examples/`
- diagnostic coverage when the feature rejects invalid source
- fixture or compile coverage when generated Zig should remain valid

## Compatibility

There is no stable compatibility promise yet. Breaking changes are acceptable
when they simplify the model or make costs more visible, but they should update
examples, generated API docs, and tests in the same change.
