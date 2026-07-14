# Release Asset Standardization Proposal

This document proposes a package-neutral release asset policy across all package repositories.
この文書は、全パッケージ公開リポジトリに対する package-neutral な release asset 方針を提案する。

## Background

Observed state on 2026-05-08:
- `devcontainer-bootstrap`: historical releases had missing custom assets on some tags.
- `ai-dotfiles`: custom assets are currently not attached.

2026-05-08 時点の観測:
- `devcontainer-bootstrap`: 一部タグで custom assets 欠落が発生した履歴がある。
- `ai-dotfiles`: 現在 custom assets 未添付。

Problem:
- Release behavior differs by package, making user expectations and operational checks inconsistent.
- Source archives (auto-generated zip/tar.gz) are not enough for deterministic consumption contracts.

課題:
- パッケージごとに release 挙動が異なり、利用者期待と運用チェックが不統一。
- 自動生成 source archive のみでは、決定的な配布契約として不足がある。

## Goals

- Define a minimal, reusable release-asset baseline for all package repositories.
- Preserve package neutrality (no project-specific proper nouns in package logic).
- Keep release operations idempotent when a release already exists.

目標:
- 全パッケージ公開リポジトリで共通の最小 release-asset 基準を定義する。
- package neutrality を維持する（パッケージ層への固有名詞混入を避ける）。
- 既存 release がある場合でも冪等に更新できる運用を維持する。

## Options

### Option A: Keep current behavior

- dotfiles continues without custom assets.
- DCB keeps script assets only.

Pros:
- No migration cost.

Cons:
- Inconsistent release contract.
- Harder automated verification.

### Option B: Minimal standardized assets (Recommended)

Attach the following assets for every package release:
1. `RELEASE-MANIFEST.json`
2. `SHA256SUMS`
3. `PACKAGE_ARCHIVE.tar.gz` (canonical package payload for that repository)

Pros:
- Uniform contract across all repositories.
- Supports automated integrity verification.
- Still package-neutral and tool-agnostic.

Cons:
- Requires small release pipeline updates for dotfiles.

### Option C: Full executable assets per package

- Attach executable entrypoints for all packages.

Pros:
- Convenient for direct downloads.

Cons:
- Not always meaningful (for doc/rule-centric packages).
- Higher maintenance burden.

## Recommendation

Adopt Option B for all package repositories.
全パッケージ公開リポジトリで Option B を採用する。

Rationale:
- Balances operational consistency and maintenance cost.
- Avoids overfitting distribution model to one package type.

採用理由:
- 運用一貫性と保守コストのバランスが良い。
- 特定パッケージ型への過剰最適化を避けられる。

## Proposed Asset Contract

### Required assets (all packages)

- `RELEASE-MANIFEST.json`
- `SHA256SUMS`
- `PACKAGE_ARCHIVE.tar.gz`

### Optional package-specific assets

- Additional executable scripts or helper files may be attached.
- Optional assets must not replace required assets.

任意アセット:
- 追加の実行スクリプトや補助ファイルを添付してよい。
- ただし必須アセットを置き換えてはならない。

### Manifest schema (minimum)

```json
{
  "package": "ai-dotfiles|devcontainer-bootstrap",
  "tag": "vX.Y.Z",
  "commit": "<git-sha>",
  "created_at": "<ISO8601>",
  "assets": [
    {"name": "PACKAGE_ARCHIVE.tar.gz", "sha256": "..."},
    {"name": "SHA256SUMS", "sha256": "..."}
  ]
}
```

## Rollout Plan

### Phase 1: Policy + tooling update (this repository)

- Extend `scripts/release-packages.sh` to generate standard assets for dotfiles.
- Add a release audit command that checks required asset presence by repo/tag.
- Keep DCB existing script assets as package-specific optional assets.

### Phase 2: Backfill existing releases

- For dotfiles, backfill missing required assets for maintained historical tags.
- Record backfill result in release notes or ops log.

### Phase 3: Gate enforcement

- Add CI/release preflight check: fail if required assets are missing.
- Add runbook checklist item for asset contract verification.

## Acceptance Criteria

- Every new release in all package repos includes required assets.
- Release creation/update is idempotent (existing release can be repaired by upload/edit).
- A single audit command reports pass/fail for required assets across package repos.

受け入れ条件:
- 全パッケージの新規リリースに必須アセットが含まれる。
- release は冪等更新可能（既存 release でも upload/edit で修復可能）。
- 共通監査コマンドで package repos 横断の pass/fail を判定できる。

## Non-Goals

- Forcing package-specific executable assets on all packages.
- Rewriting historical tags.

非目標:
- 全パッケージに実行可能アセットを強制すること。
- 過去タグを書き換えること。

## Open Questions

1. Canonical archive naming convention by package (`PACKAGE_ARCHIVE.tar.gz` vs package-specific names).
2. How many historical tags to backfill (all tags vs latest N tags).
3. Whether to publish a machine-readable release index in each repository.

## Suggested Next Action

Create an implementation issue titled:
- `implementation: standardize package release assets across dotfiles/DCB`

Include:
- scope.in: update release script, add audit command, backfill latest tags.
- acceptance: required assets present and verified by audit command.
- task_command: run release preflight + asset audit in CI.
