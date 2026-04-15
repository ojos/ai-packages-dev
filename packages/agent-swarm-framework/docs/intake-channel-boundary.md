# Intake Channel Boundary Memo

This memo captures current decisions and assumptions about Intake Manager scope and Slack integration.
This document is a planning note to reduce drift across milestones.

## Current State (as of 2026-04-14)

- ASF workflow enforcement is implemented at execution boundaries (for example pre-commit and pre-push gates).
- Intake Manager role is defined, but chat-session level enforcement is not fully automated.
- IDE-first development flow is the near-term primary milestone.
- Slack is a supporting entry point in the near term.

## Product Direction

1. Near term:
- Make IDE-first flow work end-to-end with stable quality.
- Keep Slack as a supplemental intake path.

2. Next step:
- Upgrade Slack path so it can perform equivalent intake-to-implementation flow.
- Target a balanced operation where IDE and Slack can be used with similar capability.

## Separation Decision

Decision: keep Slack adapter separated from ASF core responsibilities.

Rationale:
- Preserve package neutrality in `packages/**`.
- Keep core reusable across channels.
- Allow independent release pace and risk isolation for channel integrations.

## Boundary Rule

Place in ASF core:
- Intake contract and validation semantics.
- Command/state transition rules.
- Orchestration execution and audit logs.

Place in Slack adapter:
- Slack-specific message handling, thread UX, and channel interaction.
- Slack identity mapping and channel-specific auth checks.
- Mobile-friendly prompts and confirmation UX.

Do not duplicate in adapter:
- Core transition logic.
- Source-of-truth command validation.

## Enforcement Scope Clarification

- Current mandatory enforcement: execution gate (commit/push path).
- Not yet mandatory by mechanism: conversation entry must always start via Intake Manager.
- Future enhancement option: conversation gateway that routes implementation intent through Intake Manager before execution.

## Implementation Strategy

1. Phase 1 (now):
- Stabilize IDE-first flow and enforce ASF at execution boundaries.

2. Phase 2:
- Define stable Intake I/O contract between core and adapters.
- Build Slack adapter as supplemental channel using the same contract.

3. Phase 3:
- Reach functional parity between IDE and Slack entry paths.
- Keep one shared validation/orchestration core.

## Trade-off Summary (Intake Manager strict enforcement)

Potential gains:
- Higher requirement consistency.
- Better reproducibility and handover quality.
- Better downstream automation quality.

Potential losses:
- Lower speed for tiny tasks.
- Reduced exploratory conversation freedom.
- Higher interaction overhead on mobile.

Recommended policy:
- Keep strict enforcement on execution gates.
- Introduce staged intake enforcement before implementation actions, not before all conversations.

## Open Questions

- Exact trigger point for mandatory intake in chat flows.
- Emergency bypass policy and required audit fields.
- Minimal mobile interaction set for Slack path.

## Review Trigger

Revisit this memo when one of the following occurs:
- Slack path starts implementation tasks regularly.
- Core and adapter responsibilities become duplicated.
- Team requests fully mandatory intake at conversation start.
