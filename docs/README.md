# Documentation

This directory contains the design and implementation notes for the Zig++
prototype. Start with the design draft for intent, then use the more focused
documents when working on code or reviewing changes.

## Design

- [Zig++ Design Draft v0.1](zigpp-design-draft-v0.1.md): original language
  concept, goals, non-goals, and roadmap sketch
- [Roadmap](../ROADMAP.md): implementation phases and stabilization criteria

## Implementation

- [Architecture](architecture.md): repository structure, module boundaries,
  tool flow, build steps, fixtures, and generated artifacts
- [Lowering Rules](lowering-rules.md): current `.zpp` to Zig lowering contract
- [Diagnostics](diagnostics.md): ownership checks, effect checks, severities,
  and known limits
- [Tool Reference](tool-reference.md): CLI commands, common workflows, options,
  and exit behavior
- [Package Tools](package-tools.md): `zpp-doc`, `zpp-api`, `zpp-package`,
  API manifests, compatibility checks, and CI policy

## Generated Artifacts

- [Example Package API Docs](zigpp-examples-api.md): generated Markdown API
  notes for the checked-in examples
- [Example Package API Manifest](zigpp-examples.api.jsonl): generated JSON
  Lines API baseline used by package checks

## Contributor Entry Points

Use these docs by task:

- changing syntax or generated Zig: read
  [Lowering Rules](lowering-rules.md) and [Architecture](architecture.md)
- changing diagnostics: read [Diagnostics](diagnostics.md)
- using or changing CLI behavior: read [Tool Reference](tool-reference.md)
- changing package manifests, API extraction, or generated docs: read
  [Package Tools](package-tools.md)
- changing project direction: read [Zig++ Design Draft v0.1](zigpp-design-draft-v0.1.md)
  and [Roadmap](../ROADMAP.md)

The central rule across all documents is that high-level features must keep
allocation, cleanup, dispatch, unsafe behavior, and control flow visible.
