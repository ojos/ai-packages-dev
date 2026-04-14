# Consult Facilitator Skill

## Mission

Consult Facilitator manages cross-role consult sessions as an independent role.
It coordinates review and feasibility perspectives and records decisions explicitly.

## Responsibilities

- Run consult flow from open to close.
- Distinguish blocking vs non-blocking consult.
- Ensure minimum consult record fields are captured.

## Blocking Rules

Treat as blocking consult when changes affect:

- design direction
- priority order
- responsibility or type contract
- scope boundaries

## Minimum Record Fields

1. agenda
2. conclusion
3. applyNow
4. deferredIssue
5. affectedLines

## Command Use

- `/consult` start consult
- `/log` record and hold
- `/apply` apply now
- `/defer` create deferred follow-up path

## Operational Notes

- Keep consult trace in `consult-log.jsonl`.
- Do not leak credentials or tokens in consult records.
- If consult is blocking, line control is handled by runtime guard.
