# Package Distribution Contract

## Scope
- This document defines distribution boundaries for `packages/agent-swarm-framework`.
- Target: reusable package delivery for multi-agent workflow bootstrap.

## Included Artifacts
- `install.sh`
- `init.sh`
- `config.schema.json`
- `runtime-core/`
- `agent-skills/`
- `executors/`
- `template-project/`
- `docs/`

## Excluded Artifacts
- Runtime logs under `orchestration/runtime/`
- Any local secrets or tokens
- Workspace-specific generated files

## Versioning
- Canonical version file: `packages/agent-swarm-framework/VERSION`
- Config schema version: `config.schema.json` field `version`
- Release tag format: `agent-swarm-framework-v<version>`
- Release notes must summarize change impact.

## Release Workflow
- This monorepo currently does not publish ASF GitHub Releases directly.
- Release automation must be executed in a dedicated ASF release repository.
- Recommended trigger: push tag matching `agent-swarm-framework-v*`.
- Published assets contract:
  - `agent-swarm-framework-<version>.tar.gz`
  - `SHA256SUMS`
- Release notes include commit SHA, package version, schema version, and executed validations.

## Install Contract
- Interactive install:
  - `bash packages/agent-swarm-framework/install.sh`
- Non-interactive install:
  - `bash packages/agent-swarm-framework/install.sh --non-interactive --config <config.json> --target-dir <path>`

## Responsibility Boundary
- `runtime-core/`: runtime scripts and queue/worker orchestration primitives
- `agent-skills/`: role-specific instruction packs
- `executors/`: remote execution adapters
- `template-project/`: reusable project bootstrap assets
