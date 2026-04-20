# Slack Intake Adapter (Dedicated-First, Shared-Compatible)

## English Summary
This document defines phase-1 adapter contract and operation model for Slack intake integration with ASF.

## Goals
- Dedicated workspace is the primary operation model.
- Shared private-channel mode remains compatible.
- Adapter emits normalized payload for existing ASF intake flow.

## Input Contract (Slack -> Adapter)
- event_id
- team_id
- channel_id
- user_id
- text
- ts

## Output Contract (Adapter -> ASF)
- channel_type: slack
- source.workspace_mode: dedicated | shared
- source.channel_id
- source.user_id
- intake.raw_text
- intake.command_text
- safety.auth_validated: true | false

## Safety Rules
- Reject unauthorized channel/user by policy.
- If runner unavailable, emit deferred/queued outcome with explicit message.
- Keep core workflow channel-independent.

## Rollout Notes
- Phase-1 scope is contract + operation guardrails.
- Runtime implementation hooks can be added in subsequent issue steps.

## Phase-2 Runtime Hook (2026-04-20)

### Runtime Hook Path
- `runtime-core/files/scripts/gate/slack-intake-hook.sh`

### Behavior
- validates channel/user metadata
- rejects when `safety.auth_validated != true`
- emits deferred outcome when `runtime.runner_available != true`
- emits dispatch-ready normalized intake payload when safe

### Rollback
1. stop workers with `bash scripts/worker/workers-stop.sh`
2. disable caller path to slack-intake-hook until validation policy is corrected
3. replay deferred queue after runner recovery
