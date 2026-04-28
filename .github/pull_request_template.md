## Summary

Describe the focused change and why it belongs in the Zig++ draft.

## Visibility Checklist

- [ ] Generated Zig remains readable.
- [ ] Allocation remains explicit.
- [ ] Cleanup remains explicit.
- [ ] Dynamic dispatch remains visible with `dyn` when used.
- [ ] Unsafe behavior remains visible when used.
- [ ] The change does not introduce hidden control flow.

## Validation

- [ ] `zig build test`
- [ ] `zig build fixture-test`
- [ ] `zig build compile-fixtures`
- [ ] `zig build package-zpp -- zpp-package.json --audit`
- [ ] `zig build package-zpp -- zpp-package.json --api-check`

## Notes
