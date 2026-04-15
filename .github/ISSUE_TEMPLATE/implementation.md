---
name: Implementation Task
about: Scoped implementation work within ASF workflow requiring delegation review
labels: implementation,asf-workflow
---

## English Summary (Required)

<!-- Keep this section short (2-6 lines). Include intent, scope, and expected outcome in English. -->

## 日本語詳細 / Japanese Details

<!-- 日本語での背景・補足説明を記載。英語要約と矛盾しないこと。 -->

## Runtime Dispatch Note

<!-- Creating this issue alone does not start line execution. After scope is ready, dispatch executable work with scripts/worker/delegate-issue-implementation.sh. -->

## 📋 Implementation Scope

<!-- Explicit scope helps delegation decision -->

### Files to create/modify
- [ ] List files or wildcards (e.g., `scripts/gate/**.sh`, `packages/agent-swarm-framework/...`)

### Acceptance Criteria
- [ ] (Add criteria here)
- [ ] All tests pass
- [ ] Parity maintained (root/runtime-core if applicable)
- [ ] Code reviewed before merge

### Test Coverage Required
- [ ] Unit tests: YES / NO
- [ ] Integration tests: YES / NO
- [ ] E2E tests: YES / NO

### Breaking Changes?
- [ ] None
- [ ] Minor (backward compatible)
- [ ] Major (breaking change)

---

## 🤝 Delegation Metadata

### For Agent Coordination

**Delegation Status**: 
- [ ] Requires code review before implementation (**delegate to line worker**)
- [ ] Can be self-implemented by agent (small/doc task)
- [ ] Awaiting line worker assignment

**Estimated Effort**:
- [ ] small (< 1 hour)
- [ ] medium (1-4 hours)
- [ ] large (> 4 hours)

**Blocking Other Work?**
- [ ] NO (can proceed in parallel)
- [ ] YES (blocking: [list issues])

---

## 📝 Implementation Notes

<!-- Optional: Add context for implementer -->

