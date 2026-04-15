# Shared AI Rules & Definitions

This package contains shared rule definitions and role specifications for AI agent interactions across projects.
It serves as the source of truth for common development guidelines, role instructions, and versioning policies.

## Scope

This directory manages cross-project reusable configurations:

- Common development rules and AI interaction guidelines
- Implementation and review role instructions
- Shared versioning and operational policies
- Role and responsibility definitions

Project-specific requirements, design decisions, handover details, and operational procedures remain the responsibility of individual projects.

## Boundary with ASF

This package provides shared environment and language-level AI rules.
Workflow-specific orchestration policies are owned by ASF.

- dotfiles owns: shared AI writing/development rules, common instruction style, reusable environment conventions
- ASF owns: delegation workflow, conversation-gate reason codes, role coordination behavior

For ASF-specific workflow policies, refer to:
- `packages/agent-swarm-framework/README.md`
- `packages/agent-swarm-framework/docs/CONVERSATION_GATE_REASON_CODES.md`

## Managed Content

Currently managed files:

- `ai/common/shared-ai-rules.md` — Cross-role AI rules and behavior patterns
- `ai/common/claude-instructions.md` — Claude-specific instructions
- `ai/common/gemini-instructions.md` — Gemini-specific instructions

## Core Principles

- This package manages AI development settings common to all projects
- Project names and project-specific information must not be embedded in version names or file structure
- Adopting projects must explicitly pin specific versions rather than following main continuously
- Following the latest main branch is not recommended

## Versioning Policy

This package follows Semantic Versioning (SemVer) with tag format: `vX.Y.Z`

Initial release: `v0.1.0`

### MAJOR

Update for changes that could break existing project operations:
- Changes to file path structure
- Deletion or renaming of required reference files
- Significant changes to operational prerequisites

### MINOR

Update for backward-compatible feature additions or rule additions:
- New common guidelines
- Operational procedure additions
- Improvements that do not break existing rules

### PATCH

Update for minor corrections:
- Typo fixes
- Clarity improvements in explanations
- Non-semantic wording corrections

## Adoption Guidelines for Projects

Projects using this package should follow these practices:

- Record both tags and commit SHAs for full traceability
- Use tags as human-readable identifiers
- Use commit SHAs for precise reproduction
- Never pin to `latest` or `main` as a fixed reference
- Perform updates via manual review, not automatic pull

## Update Procedures

- When changing common rules, update this repository first
- Projects can adopt changes via submodule, subtree, or manual synchronization
- Regardless of method, adopting projects must record the adopted tag and commit SHA
- Public distribution is acceptable; consuming projects must pin specific versions rather than auto-tracking latest

## Installation Script Policy

Current decision: this package does not provide an installation shell script.

Rationale:
- The package currently contains only documentation/rule assets and no executable runtime components.
- Projects already adopt this package through explicit version pinning (tag + commit SHA), which is the required safety control.
- Adding an installer now would increase maintenance and compatibility burden without meaningful operational benefit.

Adoption methods:
- Submodule, subtree, or manual sync with explicit version pinning

Revisit trigger:
- Add an installer only when this package gains executable assets that require deterministic setup steps.

## File Sync Rules

- `README.md` is the English normative version
- `README.ja.md` is the Japanese translation (kept in sync with README.md)
- When updating, edit both files together to maintain synchronization
- Never allow translation drift; both versions must reflect identical intent

## Documentation

For detailed AI guidance and role specifications:
- [ai/common/shared-ai-rules.md](ai/common/shared-ai-rules.md) — Core rules and patterns
- [ai/common/claude-instructions.md](ai/common/claude-instructions.md) — Claude-specific behavior
- [ai/common/gemini-instructions.md](ai/common/gemini-instructions.md) — Gemini-specific behavior
