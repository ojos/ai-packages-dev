# devcontainer-bootstrap Release Notes

## v0.3.0

### Summary
- 規範パッケージの改名（`dotfiles` → `ai-playbook`）に追随し、AI 共通ルールの取得・配置を新構造へ移行。

### Highlights
- オプションを `--with-dotfiles` から `--with-playbook` へ改名（`--playbook-from` で取得元タグ tarball を指定）。
- 規範の配置先を `.ai-playbook/`（ドット接頭辞・フラット構造）へ変更。
- 取得元の既定を新しい配布リポジトリ `ojos/ai-playbook`（git タグのみ・Release なし）の archive tarball に更新。
- 配置時にファイル権限を正規化（生成物の `mktemp` 由来の過剰な制限を解消し、通常ファイル 644 / スクリプト 755 に揃える）。

### Breaking Changes
- `--with-dotfiles` は廃止。新規に規範を配置する場合は `--with-playbook --playbook-from <ai-playbook タグ tarball>` を使う。
- 旧配布リポジトリ `ojos/ai-dotfiles` は廃止。取得元は `ojos/ai-playbook` へ移行する。

### Verification
- [x] DCB テストスイート全 6 ファイル成功（URL / ディレクトリ / 隣接の 3 経路、権限、テンプレート一致、リリース契約）
- [x] `ojos/ai-playbook` v0.1.0 の archive tarball が取得でき `shared-ai-rules.md` を含むことを確認
- [x] パッケージ中立性・Shell lint・ドキュメント整合の CI 通過

## v0.2.1

### Summary
- Stable release for devcontainer bootstrap environment loading and GitHub account switching reliability updates.

### Highlights
- `.env` files in the project root are now loaded automatically before bootstrap follow-up commands run.
- Project-specific `.env` values override `remoteEnv` values when the same key is defined in both places.
- GitHub account auto-selection now falls back to the first declared `GITHUB_TOKEN_*` profile when no explicit profile is set.

### Included Changes
- `scripts/load-env.sh` for project-root `.env` loading
- devcontainer lifecycle command updates to source project environment first
- `scripts/github-account-switch.sh` auto-profile fallback improvement

### Verification
- [x] bash syntax check for `scripts/load-env.sh`
- [x] `.env` override behavior verified via sourced shell test
- [x] `scripts/github-account-switch.sh` syntax check passed
- [x] `auto` fallback to first declared `GITHUB_TOKEN_*` verified with a stubbed `gh`
