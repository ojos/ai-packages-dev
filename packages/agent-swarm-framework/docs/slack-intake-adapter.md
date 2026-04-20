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
