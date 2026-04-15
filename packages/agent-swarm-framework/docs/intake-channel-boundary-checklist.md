# Intake Channel Boundary Checklist

This checklist converts boundary decisions into implementation tasks.
Use it to keep ASF core and channel adapters separated consistently.

## Scope

- Applies to IDE-first ASF development now.
- Applies to Slack adapter design and implementation later.

## A. Design Gate (before coding)

- [ ] Responsibility split is explicit:
  - [ ] ASF core responsibilities are listed.
  - [ ] Adapter responsibilities are listed.
- [ ] No channel-specific nouns in core design docs.
- [ ] Intake I/O contract fields are defined and versioned.
- [ ] Validation source of truth is assigned to ASF core.
- [ ] Error model is shared across IDE and adapter paths.

Definition of done for A:
- A design note includes: core scope, adapter scope, and contract schema owner.

## B. Core Implementation Gate

- [ ] Command/state transition logic is implemented only once in core.
- [ ] Core does not import adapter SDK dependencies.
- [ ] Core accepts normalized command payloads (channel-agnostic).
- [ ] Core writes audit logs independent of entry channel.
- [ ] Core tests cover both IDE-origin and adapter-origin payload examples.

Definition of done for B:
- Core tests pass with at least one IDE and one adapter-shaped input fixture.

## C. Adapter Implementation Gate (Slack or other)

- [ ] Adapter converts channel events into normalized Intake/command payloads.
- [ ] Adapter does not re-implement transition rules.
- [ ] Adapter calls core validation before execution requests.
- [ ] Adapter-specific auth and identity mapping are isolated in adapter layer.
- [ ] Mobile-friendly confirmation flow exists for destructive actions.

Definition of done for C:
- Adapter can submit intake and receive validation errors from core without custom rule forks.

## D. Enforcement Gate

- [ ] Execution boundary enforcement remains active (commit/push gate).
- [ ] Mandatory intake trigger point is documented for each channel.
- [ ] Bypass policy exists with required audit fields.
- [ ] Emergency mode does not bypass core validation logs.

Definition of done for D:
- Enforcement behavior is testable and documented with one success and one reject scenario.

## E. Release Gate

- [ ] Core release notes include contract compatibility statement.
- [ ] Adapter release notes include supported contract version.
- [ ] Backward compatibility policy is explicit for contract changes.
- [ ] README/docs link both boundary memo and this checklist.

Definition of done for E:
- A release reviewer can verify compatibility from docs alone.

## Regression Quick Checks

1. If adapter is disabled, IDE-first path still works end-to-end.
2. If adapter is enabled, command validation results match IDE path behavior.
3. No channel-specific dependency appears under `packages/agent-swarm-framework/runtime-core/**`.

## Ownership Recommendation

- Core owner: ASF maintainers.
- Adapter owner: channel integration maintainers.
- Contract owner: shared ownership with explicit approval rule from core owner.
