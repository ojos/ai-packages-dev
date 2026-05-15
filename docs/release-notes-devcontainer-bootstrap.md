# devcontainer-bootstrap Release Notes

## Summary
- Stable release for devcontainer bootstrap environment loading and GitHub account switching reliability updates.

## Highlights
- `.env` files in the project root are now loaded automatically before bootstrap follow-up commands run.
- Project-specific `.env` values override `remoteEnv` values when the same key is defined in both places.
- GitHub account auto-selection now falls back to the first declared `GITHUB_TOKEN_*` profile when no explicit profile is set.

## Included Changes
- `scripts/load-env.sh` for project-root `.env` loading
- devcontainer lifecycle command updates to source project environment first
- `scripts/github-account-switch.sh` auto-profile fallback improvement
- public release documentation refresh for v0.1.14

## Verification
- [x] bash syntax check for `scripts/load-env.sh`
- [x] `.env` override behavior verified via sourced shell test
- [x] `scripts/github-account-switch.sh` syntax check passed
- [x] `auto` fallback to first declared `GITHUB_TOKEN_*` verified with a stubbed `gh`

## Notes
- Fill exact commit range if you want to reference the release diff more precisely.
