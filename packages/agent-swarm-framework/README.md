# Agent Swarm Framework

This package bootstraps multi-agent development workflows into a new or existing repository.
It provides runtime scripts, role skills, executor templates, and installation flows.

## Package Layout

```
packages/agent-swarm-framework/
├── install.sh              # entrypoint (interactive / non-interactive)
├── config.schema.json      # config JSON schema (canonical)
├── README.md               # this file
├── runtime-core/           # runtime base (workflow / command / monitor / worker)
├── agent-skills/           # role-specific skills (5 roles)
├── executors/              # remote executors (github-actions)
├── template-project/       # project templates (config / issues / milestones)
└── docs/                   # documentation
    ├── install.md          # CLI reference
    ├── architecture.md     # directory structure and design
    └── VISION_AUTONOMOUS_ORCHESTRATION.md
```

## Usage

```bash
# Interactive wizard
bash packages/agent-swarm-framework/install.sh

# Non-interactive (CI)
bash packages/agent-swarm-framework/install.sh \
  --non-interactive \
  --config my-config.json \
  --target-dir /path/to/project

# Standalone (download install.sh alone)
curl -fsSL https://raw.githubusercontent.com/ojos/agent-swarm-framework/main/install.sh \
  -o install.sh && \
bash install.sh --non-interactive --config my-config.json --target-dir /path/to/project --skip-github
```

Installation flow:

1. Collect config from wizard or JSON file
2. Generate preview in `.preview/<projectSlug>/`
3. Review category files (add/overwrite)
4. Apply selected categories to target repo
5. Optionally create milestone/bootstrap issues on GitHub

### Retrofit (Staged Adoption)

ASF can be adopted into existing repositories, not just new ones.
Start with `--retrofit-safe` + `automationStage=plan` for audit mode, then gradually unlock `implement/review/merge`.

- `--retrofit-safe` enforces safe defaults:
  - `executionMode=local`
  - `remoteProvider=none`
  - `mergePolicy=manual`
  - `orchestratorMode=local`
  - auto-enables `--skip-github`
- Default categories for retrofit:
  - Apply: `runtime-core`, `agent-skills`
  - Skip: `executors`, `template-project`
- See `retrofit-config.sample.json` for details.
- Full retrofit workflow: [docs/install.md](docs/install.md#retrofit)

### Standalone Execution

When `install.sh` is run standalone (download only):
- If bundled package directories are missing, `install.sh` auto-fetches the package archive and re-runs.
- Default fetch source: main branch archive.
- Override with `--bootstrap-from <url>` or `AGENT_SWARM_FRAMEWORK_ARCHIVE_URL`.

For full details, see [docs/install.md](docs/install.md).

---

## Default Configuration

| Setting | Default |
|---------|---------|
| execution mode | `hybrid` |
| remote provider | `github-actions` |
| automation stage | `implement` |
| merge policy | `manual` |
| line strategy | `fixed2` |
| orchestrator mode | `remote` |
| state backend | `hybrid` |

---

## Version Policy

| Item | Policy |
|------|--------|
| Schema version | from `config.schema.json` `version` field (current: `"1.0"`) |
| Backward compatibility | Not guaranteed across major versions (1.x → 2.x) |
| Change management | Update `version` on schema changes; also update `install.sh` validation |
| Canonical path | `packages/agent-swarm-framework/config.schema.json` |
| Distribution unit | Entire directory via `git archive` or `tar.gz` |

---

## Documentation

- [docs/install.md](docs/install.md) — CLI reference and config field spec
- [docs/architecture.md](docs/architecture.md) — directory structure and design
- [docs/VISION_AUTONOMOUS_ORCHESTRATION.md](docs/VISION_AUTONOMOUS_ORCHESTRATION.md) — autonomous orchestration vision
- [docs/github-actions.md](docs/github-actions.md) — GitHub Actions executor details
- [docs/runtime-operations.md](docs/runtime-operations.md) — release procedures and operations
- [docs/STATE_MANAGEMENT.md](docs/STATE_MANAGEMENT.md) — state management details
- [docs/PACKAGE_DISTRIBUTION.md](docs/PACKAGE_DISTRIBUTION.md) — distribution, boundaries, version rules

---

## FAQ & Troubleshooting

| Symptom | Solution |
|---------|----------|
| `gh: command not found` | Install GitHub CLI and run `gh auth login` |
| `jq: command not found` | Install: `apt install jq` or `brew install jq` |
| `error: --non-interactive requires --config` | Always use `--config <file>` with `--non-interactive` |
| Files unexpectedly overwritten | Check preview's "overwrite" section before applying |
| milestone/issue not reflected | Check `--skip-github` flag and `gh auth status` |
