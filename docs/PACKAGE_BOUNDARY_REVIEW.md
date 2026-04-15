# Package Boundary Review (B-2)

## 問題設定

**現状**: dotfiles と ASF が両方 AI behavior を定義している
- `dotfiles/ai/common/shared-ai-rules.md` — 汎用言語方針・命名規則
- `packages/agent-swarm-framework/docs/CONVERSATION_GATE_REASON_CODES.md` — ASF 固有の reason_code
- `packages/agent-swarm-framework/agent-skills/` — ASF specific skills

**質問**: これらが単一 package として独立すべきか、結合すべきか？

---

## 境界分析

### dotfiles の責務

| 内容 | 現在地 | 性質 |
|------|--------|------|
| 言語方針（英語命名） | `shared-ai-rules.md` | **汎用** |
| 命名規則 | `shared-ai-rules.md` | **汎用** |
| AI behavior 基本ルール | `.instructions.md` | **汎用** |
| Project-specific policy | `.github/PROJECT_DEFINITION.md` | **プロジェクト固有** |

**特性**: Dev container, shell config, shared rules → **Environment setup**

### ASF の責務

| 内容 | 現在地 | 性質 |
|------|--------|------|
| Conversation gate reason_codes | `docs/CONVERSATION_GATE_REASON_CODES.md` | **ASF 固有** |
| Delegation pattern rules | `copilot-instructions.md` (in ASF template) | **ASF 固有** |
| Agent skills | `agent-skills/files/` | **ASF 固有** |
| Workflow coordination | `runtime-core/scripts/` | **ASF 固有** |

**特性**: Workflow orchestration, coordination, skills → **Workflow engine**

---

## 機能的オーバーラップ分析

### 🔴 重複エリア: AI Agent Behavior Definition

**Dotfiles 側**:
```yaml
# shared-ai-rules.md
- Use English naming for code
- Use Japanese comments for clarification
- Keep function names lowercase_with_underscores
```

**ASF 側**:
```yaml
# copilot-instructions.md + delegation pattern
- Delegation triggers
- When to implement vs delegate
- Consult log recording patterns
```

**問題**: 両方が「AI behavior」を定義している → **Policy ownership unclear**

---

## Design Options

### Option A: Keep Split (現状維持)

**Rationale**:
- dotfiles = shared environment rules
- ASF = workflow-specific coordination rules
- Clean separation of concerns

**Pros**:
- ✅ Reuse potential: dotfiles は複数 project で使用可能
- ✅ ASF は dotfiles に依存しない独立性
- ✅ Maintenance: 関心の分離

**Cons**:
- ❌ Duplication risk: AI behavior definition が split
- ❌ Consistency: 両方を update する必要あり
- ❌ Onboarding: New contributor は両方読む必要

### Option B: Consolidate to ASF

**Rationale**: ASF が workflow coordination の source of truth

**Pros**:
- ✅ Single source of truth for AI behavior
- ✅ Easier maintenance (one place to update)
- ✅ Clearer semantics: workflow package = behavior engine

**Cons**:
- ❌ ASF が heavier になる
- ❌ dotfiles の reusability 低下
- ❌ ASF に policy layer が over-loaded

### Option C: Consolidate to Dotfiles

**Rationale**: dotfiles が shared policies の source

**Pros**:
- ✅ dotfiles が single point of truth
- ✅ All projects inherit consistent behavior
- ✅ ASF remains lightweight

**Cons**:
- ❌ dotfiles が heavier になる
- ❌ ASF が behavior-agnostic (tooling only)
- ❌ Workflow-specific rules (reason_codes) が dotfiles に混在

### Option D: Create Unified AI Policy Package

**Rationale**: AI behavior を第 3 の package として統一

Structure:
```
packages/
  ├── ai-policies/          ← NEW
  │   ├── shared-rules.md
  │   ├── delegation-pattern.md
  │   ├── reason-codes.md
  │   ├── skills/
  │   └── README.md
  ├── agent-swarm-framework/
  │   ├── runtime-core/
  │   ├── executors/
  │   └── README.md
  └── dotfiles/
      └── (config files only)
```

**Pros**:
- ✅ Clear separation: policies ≠ implementation
- ✅ Both ASF and dotfiles can consume ai-policies
- ✅ Scalable: future projects can use ai-policies independently

**Cons**:
- ❌ Increased complexity (3 packages)
- ❌ More overhead for small orgs
- ❌ Introduces new inter-package dependency

---

## Recommendation

### Current Assessment: **Option A (Keep Split) is adequate for now**

**Reasoning**:
1. **Scope**: Conversation gate reason_codes are truly ASF-specific
2. **Reuse**: dotfiles needs to remain lightweight for broad reuse
3. **Time**: Moving to Option C/D can be deferred until package ecosystem matures
4. **Complexity**: Option A keeps current cognitive load manageable

### Decision Criteria for Future Migration

**Migrate to Option C/D if**:
- Multiple projects start defining their own reason_codes (implies pattern reuse)
- Reason_code schema stabilizes (no frequent changes)
- ASF becomes primary workflow framework across org
- Dotfiles team capacity increases

**Stay with Option A if**:
- Reason_codes remain ASF-specific (current state)
- Dotfiles is used across diverse project types
- ASF and dotfiles have separate release cycles (currently true)

---

## Implementation Path

### Immediate (Next 1-2 sprints)

✅ **Keep current split**:
- dotfiles = shared environment + language policies
- ASF = workflow + coordination + reason_codes

📝 **Document clearly**:
- Add section to dotfiles README: "This package defines environment setup and language policies only. Workflow-specific policies are in ASF."
- Add section to ASF README: "This package includes workflow coordination and reason_code definitions (ASF-specific)."

### Medium-term (3-6 months)

⏰ **Monitor**:
- Are other projects creating similar reason_code patterns?
- Is duplication causing maintenance burden?
- Are new developers confused by split ownership?

📊 **Metrics**:
- Time spent updating both policies
- Number of projects consuming ai-policies vs dotfiles
- Support questions about policy location

### Long-term (6+ months)

🎯 **Decide**:
- If duplication is significant → Option C/D
- If split works well → Keep current model
- If ASF becomes standard → Option C might be natural evolution

---

## Documentation Action Items

### For dotfiles README.md
Add section:
```markdown
## Scope & Limitations

This package provides:
- Dev container configuration
- Shell environment setup
- Shared language policies (English/Japanese)
- General AI rules (applicable to any LLM usage)

This package does NOT provide:
- Workflow coordination patterns
- Project-specific orchestration
- Application-level agent behavior rules

For ASF (Agent Swarm Framework) specific policies, see:
https://github.com/ojos/agent-swarm-framework
```

### For ASF README.md
Add section:
```markdown
## Relationship to Dotfiles

ASF builds on top of dotfiles for basic environment setup but defines
its own orchestration-specific policies including:
- Delegation pattern rules
- Conversation gate reason_codes
- Agent skill definitions
- Workflow coordination patterns

ASF is independent of dotfiles (can be used standalone).
```

---

## Decision Point

**Decision Required**: Which option does the team prefer?

A. Keep split (current, recommended)
B. Consolidate to ASF
C. Consolidate to dotfiles
D. Create unified ai-policies package
E. Defer decision (re-evaluate in 6 months)

**Current Recommendation**: **Option A** - Keep split, document clearly

---

## Rationale Summary

| Aspect | Option A | Notes |
|--------|----------|-------|
| Clarity | ⭐⭐⭐ | Clear responsibilities |
| Maintenance | ⭐⭐⭐ | Two places to update, but separate concerns |
| Reusability | ⭐⭐⭐⭐ | Both packages independently useful |
| Complexity | ⭐⭐⭐⭐ | Simplest implementation |
| Future flexibility | ⭐⭐⭐⭐ | Easy to refactor later |

**Recommendation Confidence**: 75% → can be revisited based on usage patterns

