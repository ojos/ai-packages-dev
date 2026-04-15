# Design Summary: Conversation Gate Implementation (#12, #13)

このドキュメントは、設計フェーズ（#5）で確定した conversation gate 正本ルール実装の設計情報を、line worker への委譲用に整理したものです。

## Design Decisions (Locked, Q1-Q12)

### Core Concepts

**Intake Requirement Determination**:
- Input: User message + normalized auxiliary info (7 fields)
- Output: JSON contract (intake_required, reason_code, reason_message, missing_fields)
- Decision: 3 paths = implementation / exempt / bypass

**Normalized Auxiliary Fields** (5 confirmed):
```json
{
  "intent_type": "question|explain|investigate|implement|small_fix",
  "existing_issue_number": null,
  "has_edit_request": true|false,
  "draft_fields": { goal, scope.in, scope.out, constraints, acceptance, priority },
  "is_small_task_candidate": true|false,
  "channel_type": "vscode_chat|vscode_editor|slack|other",
  "bypass_requested": true|false
}
```

### Reason Code System

**Categories** (~20 codes, fully enumerated in CONVERSATION_GATE_REASON_CODES.md):
1. IMPLEMENTATION_MISSING_* (goal, acceptance, scope.in, priority, multiple)
2. *_EXEMPT (question, explain, investigate, small_fix)
3. BYPASS_APPROVED / BYPASS_REJECTED
4. EXEMPTION_UNCLEAR_* (partial field fill, ambiguity)

### Existing Issue Reuse

- If `existing_issue_number` provided: extract goal/scope/acceptance from issue body
- Merge strategy: base (input) priority > issue body補完
- Use `issue_draft_fields_from_body()` to parse markdown
- Use `merge_draft_fields()` to combine

### Architecture

**Channel-Non-Dependent Core**:
- conversation-gate.sh = normalization + decision logic (can be called from any channel)
- conversation-entry.sh = VS Code/Copilot 入口 adapter (IDE-specific)
- (Future) Slack adapter = slack 入口 adapter (separate from core)

**Entry Contract** (fixed format):
```
=== INTAKE_CONFIRMATION_BLOCK_BEGIN ===
type: orchestrator-intake
goal: ...
scope.in: ...
scope.out: ...
constraints: ...
acceptance: ...
priority: ...
reason_code: ...
reason_message: ...
missing_fields: [...]
=== INTAKE_CONFIRMATION_BLOCK_END ===
```

---

## Implementation Status

### Issue #6: Reason_Code Guide (✅ ALREADY MERGED)

**Commit**: `49aa6f3` docs(asf): add conversation gate reason_code guide

**Artifacts**:
- `packages/agent-swarm-framework/docs/CONVERSATION_GATE_REASON_CODES.md`
- `packages/agent-swarm-framework/docs/CONVERSATION_GATE_REASON_CODES.ja.md`

**Status**: ✅ Merged and deployed

---

### Issue #12: conversation-gate.sh Core (DELEGATED, AWAITING LINE WORKER)

**Files to create/modify**:
- `scripts/gate/conversation-gate.sh` (new, ~500 lines)
- `packages/agent-swarm-framework/runtime-core/files/scripts/gate/conversation-gate.sh` (distributed copy)
- `packages/agent-swarm-framework/tests/conversation-gate.sh` (test suite, ~300 lines, 24 test cases)

**Key functions**:
- `has_required_intake_fields()`: Validate 4 required fields (goal, acceptance, scope.in, priority)
- `build_missing_fields()`: List missing fields with hints
- `issue_draft_fields_from_body()`: Parse goal/scope/acceptance from GitHub issue markdown
- `merge_draft_fields()`: Merge base input with issue body补完
- `choose_implementation_reason()`: Select specific reason_code based on missing fields

**Test Verification**:
```bash
bash packages/agent-swarm-framework/tests/conversation-gate.sh
# Expected: PASS=24 FAIL=0
```

**Acceptance Criteria**:
- [x] All 24 test cases pass
- [x] Syntax validation (bash -n) passes for both root and distributed
- [x] root/runtime-core output parity verified (same input → identical output)
- [x] JSON output contract valid (intake_required, reason_code, reason_message, missing_fields)
- [x] Existing issue body補完 logic works correctly
- [x] All edge cases covered

**Status**: 🔄 Awaiting line worker PR

---

### Issue #13: conversation-entry.sh Entry Adapter (DELEGATED, AWAITING LINE WORKER)

**Files to create/modify**:
- `scripts/gate/conversation-entry.sh` (new, ~500 lines)
- `packages/agent-swarm-framework/runtime-core/files/scripts/gate/conversation-entry.sh` (distributed copy)
- `packages/agent-swarm-framework/tests/conversation-entry.sh` (test suite, 8+ test cases)

**Key features**:
1. Call conversation-gate.sh with input validation
2. If `intake_required=false`: return continue decision JSON
3. If `intake_required=true`: print fixed intake confirmation block + return decision JSON
4. With `--confirm=true`: create/reuse GitHub issue and dispatch /intake command
5. With `--dry-run=true`: preview dispatch without side effects (no GitHub API calls)
6. New flag `--check-issue-exists`: validate issue existence with error handling

**Error handling**:
- Invalid JSON in --draft-fields
- Missing required issue number for --check-issue-exists
- GitHub API failures (issue creation, issue fetch)
- Temporary file creation failures
- Dispatch script execution failures
- Graceful error JSON response with error_code (always valid JSON on error)

**Test Verification**:
```bash
bash packages/agent-swarm-framework/tests/conversation-entry.sh
# Expected: PASS=8+ FAIL=0
```

**Acceptance Criteria**:
- [ ] All 8+ test cases pass
- [ ] Syntax validation (bash -n) passes for both root and distributed
- [ ] root/runtime-core output parity verified
- [ ] Fixed confirmation block format correct (`=== INTAKE_CONFIRMATION_BLOCK_BEGIN ===` markers)
- [ ] Confirm + dry-run flow works (preview without side effects)
- [ ] Error handling returns valid JSON with error_code (always valid JSON on error)
- [ ] GitHub issue creation succeeds (with body补完)
- [ ] All edge cases handled

**Status**: 🔄 Awaiting line worker PR (depends on #12)

---

## Reference Documents for Line Worker

- [Agent Command Guide](docs/AGENT_COMMAND_GUIDE.md) — How to interpret user commands
- [Delegation Pattern Rules](.github/copilot-instructions.md) — ASF workflow enforcement
- [GitHub Issue Template](.github/ISSUE_TEMPLATE/implementation.md) — Template for new implementation issues
- [Reason Code Guide](packages/agent-swarm-framework/docs/CONVERSATION_GATE_REASON_CODES.md) — Canonical reason_code registry

---

## Rollback Context

**Why these issues were created**:
- Previous implementation (#5-#8 commits) was completed directly by agent instead of delegated to line worker
- This violated ASF coordination pattern requiring code review for implementation work
- Issues #12 and #13 establish proper delegation workflow per new standards

**Implementation files available**:
- All implementation code is preserved in repository (uncommitted after soft reset)
- Reference implementations available in git history
- Line worker can use as starting point or validate against independently written code

**Next steps after line worker delivers PR**:
1. Code review + validation (syntax, tests, parity)
2. Merge to main
3. Plan #14+ for advanced features (Slack adapter, error handling enhancements, etc.)

---

## ASF Workflow Compliance

This delegation follows the new standardized ASF coordination pattern:

✅ **Design Phase** (completed):
- Locked decisions Q1-Q12 in issue #5
- Design document created and referenced

✅ **Delegation Phase** (current):
- GitHub issues #12/#13 created with explicit scope
- Delegation decisions recorded (GitHub comments)
- Standardized instructions in `.github/copilot-instructions.md`
- Reference implementations available

⏳ **Implementation Phase** (awaiting line worker):
- Line worker creates PR with implementation
- Code review by agent/reviewer
- Tests validated
- Merge to main

---

## Success Criteria for Line Worker

Before PR submission:
- [ ] bash -n syntax check passes (both root and distributed scripts)
- [ ] All test cases pass
- [ ] root/runtime-core parity verified (diff output or side-by-side comparison)
- [ ] Error cases all return valid JSON with proper error_code
- [ ] Confirmation block format exactly matches specification
- [ ] Temporary files are cleaned up
- [ ] No hardcoded paths (use SCRIPT_DIR)

Upon PR submission:
- [ ] PR references this issue (#12 or #13)
- [ ] PR description includes test verification results
- [ ] Commit message follows project style (short title + detailed body)

Upon code review:
- [ ] All requested changes addressed
- [ ] No merge conflicts
- [ ] Ready for merge to main

