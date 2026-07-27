#!/usr/bin/env bash
# test-with-flags.sh — --mode 廃止と --with-* 装備フラグの条件配線を検証する。
#
# cloud（aws/gcp/terraform）と AI ツール（claude/gemini/copilot）は、mode ではなく
# --with-* に応じて devcontainer.json の feature/拡張、compose の永続 volume、
# install-ai-tools.sh の CLI 導入行へ条件配線される。この配線の過不足や、条件行の
# 削除で JSON/YAML が壊れないことを担保する。

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-with-flags"

has_feature() { jq -e --arg k "$2" '.features|has($k)' "$1" >/dev/null 2>&1; }
has_ext() { jq -e --arg e "$2" '.customizations.vscode.extensions|index($e) != null' "$1" >/dev/null 2>&1; }

# ── --mode は廃止（案B: 未知オプションとしてエラー） ───────────────────────────

it "--mode を渡すと未知オプションとしてエラー終了する"
out="$(new_workdir)/p"
output="$(run_bootstrap "$out" --mode standard 2>&1)"
if [[ $? -ne 0 ]] && printf '%s' "$output" | grep -q 'unknown option: --mode'; then
  pass
else
  fail "--mode が拒否されない"
fi

# ── docker のリッチさは全生成物で標準化 ───────────────────────────────────────

it "素の生成物でも buildx / compose-switch が標準装備される"
out="$(new_workdir)/p"
run_bootstrap "$out" >/dev/null 2>&1
dc="$out/.devcontainer/devcontainer.json"
if jq -e '.features["ghcr.io/devcontainers/features/docker-outside-of-docker:1"]
          |(.installDockerBuildx == true and .installDockerComposeSwitch == true)' "$dc" >/dev/null; then
  pass
else
  fail "docker のリッチさが標準化されていない"
fi

it "素の生成物に開発補助ツール（ripgrep / tmux）が常時同梱される"
# ripgrep と同様、tmux も装備フラグに依らず常時同梱する（--with-* の意味論を広げない）。
if has_feature "$dc" "ghcr.io/devcontainers-extra/features/ripgrep:1" \
   && has_feature "$dc" "ghcr.io/devcontainers-extra/features/tmux-apt-get:1"; then
  pass
else
  fail "ripgrep / tmux が常時同梱されていない"
fi

it "生成された devcontainer.json は妥当な JSON である"
if jq -e '.' "$dc" >/dev/null 2>&1; then pass; else fail "jq で解釈できない（不正な JSON）"; fi

# ── 素の生成物には cloud/AI 装備が無い ────────────────────────────────────────

it "素の生成物には cloud feature も AI 拡張も無い"
if has_feature "$dc" "ghcr.io/devcontainers/features/aws-cli:1" \
   || has_feature "$dc" "ghcr.io/dhoeric/features/google-cloud-cli:1" \
   || has_feature "$dc" "ghcr.io/devcontainers/features/terraform:1" \
   || has_ext "$dc" "anthropic.claude-code" \
   || has_ext "$dc" "github.copilot"; then
  fail "未選択なのに装備が入っている"
else
  pass
fi

it "素の install-ai-tools.sh は AI CLI を導入しない"
if grep -qE '^install_if_missing (claude|gemini|copilot)\b' "$out/scripts/install-ai-tools.sh"; then
  fail "未選択なのに AI CLI 導入行がある"
else
  pass
fi

# ── --with-aws ────────────────────────────────────────────────────────────────

it "--with-aws: aws-cli feature + aws-toolkit 拡張 + terraform が入る"
out="$(new_workdir)/p"
run_bootstrap "$out" --with-aws >/dev/null 2>&1
dc="$out/.devcontainer/devcontainer.json"
if has_feature "$dc" "ghcr.io/devcontainers/features/aws-cli:1" \
   && has_ext "$dc" "amazonwebservices.aws-toolkit-vscode" \
   && has_feature "$dc" "ghcr.io/devcontainers/features/terraform:1" \
   && has_ext "$dc" "hashicorp.terraform"; then
  pass
else
  fail "aws 装備または terraform 随伴が欠けている"
fi

it "--with-aws: gcp 装備は入らない"
if has_feature "$dc" "ghcr.io/dhoeric/features/google-cloud-cli:1"; then
  fail "gcp が漏れて入っている"
else
  pass
fi

# ── --with-gcp ────────────────────────────────────────────────────────────────

it "--with-gcp: google-cloud-cli feature + cloudcode 拡張 + terraform が入る"
out="$(new_workdir)/p"
run_bootstrap "$out" --with-gcp >/dev/null 2>&1
dc="$out/.devcontainer/devcontainer.json"
if has_feature "$dc" "ghcr.io/dhoeric/features/google-cloud-cli:1" \
   && has_ext "$dc" "GoogleCloudTools.cloudcode" \
   && has_feature "$dc" "ghcr.io/devcontainers/features/terraform:1"; then
  pass
else
  fail "gcp 装備または terraform 随伴が欠けている"
fi

it "--with-gcp: aws 装備は入らない"
if has_feature "$dc" "ghcr.io/devcontainers/features/aws-cli:1"; then
  fail "aws が漏れて入っている"
else
  pass
fi

# ── Terraform の合成条件（aws OR gcp、両指定でも 1 回） ─────────────────────────

it "--with-aws --with-gcp: terraform feature / 拡張は 1 回だけ"
out="$(new_workdir)/p"
run_bootstrap "$out" --with-aws --with-gcp >/dev/null 2>&1
dc="$out/.devcontainer/devcontainer.json"
tf_feat="$(jq -r '.features|keys[]' "$dc" | grep -c 'features/terraform:1')"
tf_ext="$(jq -r '.customizations.vscode.extensions[]' "$dc" | grep -c '^hashicorp.terraform$')"
if [[ "$tf_feat" == "1" && "$tf_ext" == "1" ]]; then pass; else fail "terraform 重複または欠落 (feat=$tf_feat ext=$tf_ext)"; fi

it "cloud 無指定なら terraform は入らない"
out="$(new_workdir)/p"
run_bootstrap "$out" --with-claude >/dev/null 2>&1
dc="$out/.devcontainer/devcontainer.json"
if has_feature "$dc" "ghcr.io/devcontainers/features/terraform:1"; then
  fail "cloud 未選択なのに terraform が入っている"
else
  pass
fi

# ── AI ツールの三点セット（CLI + 拡張 + 永続 volume） ─────────────────────────

check_ai_triple() {
  local flag="$1" ext="$2" cli="$3" vol="$4"
  local out dc compose
  out="$(new_workdir)/p"
  run_bootstrap "$out" "$flag" >/dev/null 2>&1
  dc="$out/.devcontainer/devcontainer.json"
  compose="$out/.devcontainer/compose.yaml"

  it "$flag: 拡張 $ext が入る"
  if has_ext "$dc" "$ext"; then pass; else fail "拡張 $ext が無い"; fi

  it "$flag: install-ai-tools に $cli の導入行がある"
  if grep -qE "^install_if_missing $cli " "$out/scripts/install-ai-tools.sh"; then pass; else fail "$cli 導入行が無い"; fi

  it "$flag: compose に $vol 永続 volume がある"
  if grep -q "$vol" "$compose"; then pass; else fail "$vol が無い"; fi
}

check_ai_triple --with-claude  "anthropic.claude-code"                    claude  "claude-storage"
check_ai_triple --with-gemini  "Google.gemini-cli-vscode-ide-companion"   gemini  "gemini-storage"
check_ai_triple --with-copilot "github.copilot"                           copilot "copilot-storage"

it "--with-copilot: copilot-chat 拡張も入る"
out="$(new_workdir)/p"
run_bootstrap "$out" --with-copilot >/dev/null 2>&1
if has_ext "$out/.devcontainer/devcontainer.json" "github.copilot-chat"; then pass; else fail "copilot-chat が無い"; fi

# ── 自動インストール廃止（トークン分岐が無い） ────────────────────────────────

it "install-ai-tools.sh にトークン有無の分岐が無い"
out="$(new_workdir)/p"
run_bootstrap "$out" --with-claude --with-gemini >/dev/null 2>&1
if grep -qE 'CLAUDE_CODE_OAUTH_TOKEN|GEMINI_API_KEY' "$out/scripts/install-ai-tools.sh"; then
  fail "トークン分岐が残っている"
else
  pass
fi

# ── 全部入りでも JSON/YAML が妥当 ─────────────────────────────────────────────

it "全 --with-* 指定でも devcontainer.json は妥当 JSON"
out="$(new_workdir)/p"
run_bootstrap "$out" --languages node,go,python,php,rust \
  --with-aws --with-gcp --with-claude --with-gemini --with-copilot >/dev/null 2>&1
dc="$out/.devcontainer/devcontainer.json"
if jq -e . "$dc" >/dev/null 2>&1; then pass; else fail "JSON 不正"; fi

it "全 --with-* 指定でも生成スクリプトは有効な bash 構文"
bad=""
for s in "$out"/scripts/*.sh; do bash -n "$s" 2>/dev/null || bad="$bad $(basename "$s")"; done
if [[ -z "$bad" ]]; then pass; else fail "構文エラー:$bad"; fi

it "全 --with-* 指定でも compose は docker compose config を通る"
compose="$out/.devcontainer/compose.yaml"
if command -v docker >/dev/null 2>&1; then
  if docker compose -f "$compose" config >/dev/null 2>&1; then pass; else fail "compose config 失敗"; fi
else
  if ! grep -qE '__AI_VOLUME|__WITH_|__IF_' "$compose"; then pass; else fail "未置換プレースホルダが残る"; fi
fi

it "生成物に未置換プレースホルダが残らない（devcontainer.json）"
if grep -qE '__IF_WITH_|__WITH_EXTENSIONS__|__AI_' "$dc"; then
  fail "未置換: $(grep -oE '__[A-Z_]+__' "$dc" | sort -u | tr '\n' ' ')"
else
  pass
fi

# ── doctor.sh の cloud CLI 検出（feature path の一致回帰を防ぐ） ────────────────

it "doctor: --with-aws --with-gcp の生成物で aws/gcloud/terraform を検出して判定行を出す"
out="$(new_workdir)/p"
run_bootstrap "$out" --with-aws --with-gcp >/dev/null 2>&1
output="$(bash "$PKG_DIR/doctor.sh" --target-dir "$out" 2>&1)"
if printf '%s' "$output" | grep -q 'aws command' \
   && printf '%s' "$output" | grep -q 'gcloud command' \
   && printf '%s' "$output" | grep -q 'terraform command'; then
  pass
else
  fail "cloud CLI 検出行が出ない（feature path 不一致の回帰）"
fi

# ── 永続 volume の所有権修復は fix-mount-owner.sh が担う ──────────────────────
#
# 修復対象と挙動は test-fix-mount-owner.sh で検証する。ここでは装備フラグとの
# 条件配線（選択したツールのマウント先が漏れなく対象になること）だけを見る。

it "--with-claude --with-gemini --with-copilot: 3 ツール分の修復対象が入る"
out="$(new_workdir)/p"
run_bootstrap "$out" --with-claude --with-gemini --with-copilot >/dev/null 2>&1
fmo="$out/scripts/fix-mount-owner.sh"
if grep -qF 'fix_mount "/home/vscode/.claude"' "$fmo" \
   && grep -qF 'fix_mount "/home/vscode/.gemini"' "$fmo" \
   && grep -qF 'fix_mount "/home/vscode/.copilot"' "$fmo"; then
  pass
else
  fail "選択 3 ツールの fix_mount 行が揃わない"
fi

it "install-ai-tools.sh は所有権修復を持たない（責務が分離されている）"
if grep -qE 'fix_owner|fix_mount|sudo chown' "$out/scripts/install-ai-tools.sh"; then
  fail "install-ai-tools.sh に所有権修復が残っている"
else
  pass
fi

it "修復対象が永続 volume のマウント先と一致する"
# 修復が漏れたマウント先は root:root のままになり、そのツールのログインが
# Permission denied で落ちる。compose のマウント行と突き合わせて漏れを検出する。
fixed="$(grep -oE '^fix_mount "[^"]+"' "$fmo" | sed -E 's/^fix_mount "//; s/"$//' | sort | tr '\n' ' ')"
mounted="$(grep -oE '^ +- [a-z0-9-]+-storage:[^ ]+' "$out/.devcontainer/compose.yaml" \
  | sed -E 's/^ +- [a-z0-9-]+-storage://' | sort | tr '\n' ' ')"
assert_eq "$fixed" "$mounted" "修復対象とマウント先"

it "AI ツール未選択でも gh の修復対象だけは入る"
out="$(new_workdir)/p"
run_bootstrap "$out" >/dev/null 2>&1
calls="$(grep -oE '^fix_mount "[^"]+"' "$out/scripts/fix-mount-owner.sh" | sed -E 's/^fix_mount "//; s/"$//' | tr '\n' ' ')"
assert_eq "$calls" "/home/vscode/.config/gh " "素の生成物の修復対象"

it "生成された install-ai-tools.sh が bash -n を通る（全 AI 選択）"
out="$(new_workdir)/p"
run_bootstrap "$out" --with-claude --with-gemini --with-copilot >/dev/null 2>&1
if bash -n "$out/scripts/install-ai-tools.sh" 2>/dev/null; then pass; else fail "構文エラー"; fi

exit_with_result
