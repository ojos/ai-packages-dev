# Package Release Plan (B-3)

## 概要

3つのパッケージの最終リリースを計画する。前提：
- Conversation gate 実装（#12, #13）が line worker により完了
- Package boundary 決定完了（B-2）
- Contributor identity 統一完了（B-1）

---

## Target Packages

### 1. dotfiles

**Current Version**: (check from file)

**Release Goal**: 1.0.0

**Contents**:
- Dev container configuration
- Shell environment setup
- Shared AI rules (language policies)
- Git hooks, if any

**Release Artifacts**:
- Tag: `dotfiles/v1.0.0` (or `v1.0.0` depending on convention)
- Release notes: What's included, how to use
- Changelog: List all features

**Blockers**: None known

**Est. Effort**: Low (mostly assembly, existing content)

---

### 2. agent-swarm-framework (ASF)

**Current Version**: (check from file)

**Release Goal**: v1.0.0 (or v0.9.0 if beta)

**Contents**:
- ✅ conversation-gate.sh core (issue #12 delivery)
- ✅ conversation-entry.sh entry adapter (issue #13 delivery)
- ✅ reason_code guide (issue #6, already merged)
- ✅ delegation pattern rules
- ✅ GitHub issue template
- ✅ Test suites (conversation-gate + conversation-entry)

**Release Artifacts**:
- Tag: `v1.0.0` (or per-component tags?)
- Release notes: New workflow coordination features
- Changelog: Summarize issues #5-#13 work
- Migration guide (if breaking changes)

**Blockers**:
- Line worker PR on #12, #13 must be merged first
- Integration testing (E2E verification)

**Est. Effort**: Medium (release prep, testing, documentation)

---

### 3. devcontainer-bootstrap

**Current Version**: (check from file)

**Release Goal**: 1.0.0

**Contents**:
- Dev container bootstrapping
- Dependency installation
- Configuration setup

**Release Artifacts**:
- Tag: `v1.0.0`
- Release notes
- Changelog

**Blockers**: None known

**Est. Effort**: Low (mostly existing content)

---

## Release Process (Per Package)

### Pre-Release Checklist

- [ ] Update VERSION file (or package.json version)
- [ ] Update CHANGELOG.md with all changes
- [ ] Verify tests pass (locally)
- [ ] Verify all commits from previous version to HEAD are accounted for
- [ ] Review for breaking changes
- [ ] Update README.md with "now available as v1.0.0"

### Release Execution

```bash
# 1. Create and push tag
git tag v1.0.0
git push origin v1.0.0

# 2. Create GitHub Release (automated via GitHub CLI)
gh release create v1.0.0 \
  --title "Release v1.0.0" \
  --notes-file CHANGELOG.md
```

### Post-Release

- [ ] Verify GitHub release page
- [ ] Update cross-references (if any external docs)
- [ ] Announce release (if applicable)

---

## Tagging Convention

### Option A: Flat Tagging
All tags in single namespace:
```
v1.0.0        ← Could be ambiguous for multiple packages
v1.0.1
v1.1.0
```
**Problem**: Which package is v1.0.0? Ambiguous in shared repo.

### Option B: Prefixed Tagging (Recommended)
```
dotfiles/v1.0.0
devcontainer-bootstrap/v1.0.0
agent-swarm-framework/v1.0.0
```
**Benefit**: Clear which package each tag refers to.

### Option C: Monorepo Style
```
v1.0.0 (all packages, breaking change)
```
**Benefit**: Simpler, if packages are released together.
**Problem**: Not flexible for independent release cycles.

**Recommendation**: **Option B** - Prefixed tagging for clarity

---

## Sequence & Dependencies

```
Timeline:
┌─ B-1: Contributor identity rewrite
├─ B-2: Package boundary discussion → decision
├─ Line worker PR #12 merge
├─ Line worker PR #13 merge
│
└─ Release Preparation
    ├─ Update VERSION files
    ├─ Write CHANGELOG entries
    ├─ E2E testing (if applicable)
    └─ Create GitHub releases
```

**Critical Path**:
1. Contributor identity (does not block releases, can be parallel)
2. Line worker PRs merged (#12, #13)
3. Release prep (assembly, tagging, announcement)

**Recommended Order**:
1. Merge #12 (conversation-gate.sh)
2. Merge #13 (conversation-entry.sh)
3. Do B-1 (contributor identity) in parallel
4. Do B-2 (package boundary) in parallel
5. Prepare releases (B-3)
6. Tag and publish

---

## Version Numbering

### For ASF (most complex)

**Current**: Check `packages/agent-swarm-framework/VERSION`

**Semver format**: MAJOR.MINOR.PATCH

**Decision**:
- Is conversation-gate a breaking change? → MAJOR
- Is it additive? → MINOR
- Is it a bug fix? → PATCH

Likely: **v1.0.0** (first stable release with conversation gate)

### For dotfiles & devcontainer-bootstrap

**Current**: Check respective VERSION files or package.json

Likely: **v1.0.0** (first stable release)

---

## Release Notes Template

### For Each Package

```markdown
# [Package] v1.0.0

## 🎉 Release Summary

[Brief description of what's included, key features]

## ✨ New Features

- [Feature 1]
- [Feature 2]
- [Feature 3]

## 🐛 Bug Fixes

- [Fix 1]

## 📚 Documentation

- [Doc 1]

## ⚠️ Breaking Changes

[If any]

## 🔗 Related Issues

Closes #N, #M, etc.

## 💬 Contributors

@mention team members who contributed

## 📥 Installation

[How to install/use this version]
```

---

## Changelog Assembly

### For ASF (example)

```markdown
# Changelog

## [1.0.0] - 2026-04-15

### Added
- Conversation gate core decision engine (issue #12)
  - Intake requirement determination
  - Missing field detection
  - Reason code classification (~20 codes)
  - Existing issue reuse with draft field補完
- Conversation entry IDE adapter (issue #13)
  - Fixed intake confirmation block
  - Confirm/dry-run flow
  - Error handling with error_json responses
  - `--check-issue-exists` validation flag
- ASF delegation pattern standardization
  - Agent instructions updated
  - GitHub issue template created
  - User command interpretation guide
- Comprehensive test coverage (32 test cases, 100% pass rate)

### Changed
- Copilot instructions updated with delegation rules

### Documentation
- Reason code guide (bilingual)
- Design summary for line workers
- Agent command guide for users

### Fixed
- [Any bug fixes from #5-#13 work]

### Internal
- Established line worker delegation workflow
- Created implementation archive and reference docs
```

---

## Timeline Estimate

| Task | Effort | Time |
|------|--------|------|
| B-1: Contributor identity | Medium | 45 min |
| B-2: Package boundary | Light | 30 min |
| Await line worker PR merge | - | Varies |
| Release prep (all 3 packages) | Medium | 1-2 hours |
| Tagging + GitHub releases | Light | 15 min |
| **Total** | **Medium** | **2-3 hours** |

---

## Success Criteria

After releases are published:

✅ Each package has a git tag (dotfiles/v1.0.0, etc.)
✅ GitHub release page shows release notes
✅ CHANGELOG.md is up-to-date in each repo
✅ README.md mentions new stable version
✅ No open blockers or TODOs in version commit
✅ Team can reference "use agent-swarm-framework v1.0.0" for reproducibility

---

## Decision Points

1. **Tagging convention**: Flat (v1.0.0) vs Prefixed (asf/v1.0.0)?
   → **Recommendation**: Prefixed
   
2. **Version numbers**: All v1.0.0 or different per package?
   → **Recommendation**: All v1.0.0 (aligned release)
   
3. **Release simultaneously or staggered?**
   → **Recommendation**: Simultaneous (after #12 #13 merge)

4. **Include pre-release (alpha/beta) suffix?**
   → **Recommendation**: No, go straight to v1.0.0 (tested & ready)

---

## Rollback Plan

If release has critical issue:
- Unpublish GitHub release (can be done via GitHub UI)
- Keep git tag but mark as deprecated
- Create hotfix PR and re-release with v1.0.1

---

## Notes

- Release process can start immediately after line worker PRs merge
- Documentation is already mostly ready (design docs, READMEs)
- Minimal new work needed, mostly assembly

