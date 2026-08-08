#!/usr/bin/env bash
# test-credential-sources.sh — 資格情報の供給元がコンテナ内に閉じていることを検証する。
#
# remoteEnv を絞っても、資格情報がホストから流れ込む経路は残る。
#   1. VS Code が接続のたびに ~/.docker/config.json へ書き込む credsStore
#      （コンテナ内の docker がホスト OS のキーチェーンへ問い合わせる）
#   2. system / エディタが注入した credential.helper
#      （git credential fill がホスト由来のトークンを警告なく返す）
# ここでは生成物がその 2 経路を塞げているかを、実際に汚した状態を作って確かめる。

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-credential-sources"

out="$(new_workdir)/p"
run_bootstrap "$out" >/dev/null 2>&1
OA="$out/scripts/on-attach.sh"
SETUP="$out/scripts/setup-git-identity.sh"

# ── .env.example（プロジェクト固有値の唯一の供給元） ─────────────────────────

it ".env.example が生成される"
assert_file_exists "$out/.env.example"

it ".env.example が 4 つのキーを持つ"
# GH_TOKEN の詳細（PAT 固定経路の理由・案内の出し分け）は test-gh-token-pat.sh が
# 担当する。ここでは供給元の一覧としてキーが欠けていないことだけを見る。
missing=""
for k in GEMINI_API_KEY GH_TOKEN GIT_IDENTITY_NAME GIT_IDENTITY_EMAIL; do
  grep -q "^${k}=" "$out/.env.example" || missing="$missing $k"
done
if [[ -z "$missing" ]]; then pass; else fail "不足:$missing"; fi

it ".env.example に値が入っていない（雛形として配る）"
if grep -qE '^[A-Z_]+=.+' "$out/.env.example"; then
  fail "値が書かれている: $(grep -E '^[A-Z_]+=.+' "$out/.env.example" | tr '\n' ' ')"
else
  pass
fi

it ".env.example が GIT_AUTHOR_* を使わない理由を残している"
# git 自身が読む名前を環境へ置くと、local 未設定のリポジトリでも identity が解決でき、
# user.useConfigOnly の保護が無効になる。理由が消えると次の担当者が戻してしまう。
if grep -q 'user.useConfigOnly' "$out/.env.example"; then pass; else fail "理由が書かれていない"; fi

it ".env は生成しない（利用者が作る）"
assert_file_absent "$out/.env"

it "doctor が .env.example の存在を検査する"
output="$(bash "$PKG_DIR/doctor.sh" --target-dir "$out" --strict 2>&1)"
rc=$?
if [[ "$rc" -eq 0 ]] && printf '%s' "$output" | grep -q '.env.example exists'; then
  pass
else
  fail "doctor が検査していない、または --strict が非ゼロ (rc=$rc)"
fi

# ── Docker 資格情報ヘルパーの打ち消し ────────────────────────────────────────

# on-attach.sh は git identity の適用も行う。ここでは credsStore の除去だけを見たいので、
# 関数を取り出して単体で適用する。
strip_fn="$(sed -n '/^strip_docker_creds_store()/,/^}/p' "$OA")"

it "on-attach.sh が credsStore 除去を持つ"
if [[ -n "$strip_fn" ]]; then pass; else fail "strip_docker_creds_store が無い"; fi

run_strip() {
  local home="$1"
  env HOME="$home" bash -c "
set -uo pipefail
$strip_fn
strip_docker_creds_store
" 2>&1
}

it "credsStore を除去する"
h="$(new_workdir)/h1"; mkdir -p "$h/.docker"
printf '{"credsStore":"desktop","auths":{}}\n' > "$h/.docker/config.json"
run_strip "$h" >/dev/null
if jq -e 'has("credsStore") | not' "$h/.docker/config.json" >/dev/null 2>&1; then pass; else fail "credsStore が残っている: $(cat "$h/.docker/config.json")"; fi

it "レジストリ個別の credHelpers も除去する"
h="$(new_workdir)/h2"; mkdir -p "$h/.docker"
printf '{"credHelpers":{"ghcr.io":"desktop"},"auths":{}}\n' > "$h/.docker/config.json"
run_strip "$h" >/dev/null
if jq -e 'has("credHelpers") | not' "$h/.docker/config.json" >/dev/null 2>&1; then pass; else fail "credHelpers が残っている"; fi

it "他のキーは壊さない"
h="$(new_workdir)/h3"; mkdir -p "$h/.docker"
printf '{"credsStore":"desktop","auths":{"ghcr.io":{"auth":"x"}},"experimental":"enabled"}\n' > "$h/.docker/config.json"
run_strip "$h" >/dev/null
if jq -e '.auths["ghcr.io"].auth == "x" and .experimental == "enabled"' "$h/.docker/config.json" >/dev/null 2>&1; then
  pass
else
  fail "他のキーが失われた: $(cat "$h/.docker/config.json")"
fi

it "config.json が無い環境でも失敗しない"
h="$(new_workdir)/h4"; mkdir -p "$h"
output="$(run_strip "$h")"; rc=$?
if [[ "$rc" -eq 0 ]]; then pass; else fail "非ゼロ終了 (rc=$rc): $output"; fi

it "jq が無い環境では WARN に退避する（異常終了しない）"
# 生成物は --languages に python を含まない構成でも動く必要があるため実装は jq 依存。
# その jq すら無い環境では、落とさずに WARN で可視化する。
h="$(new_workdir)/h5"; mkdir -p "$h/.docker"
printf '{"credsStore":"desktop"}\n' > "$h/.docker/config.json"
nojq="$(new_workdir)/nojq"; mkdir -p "$nojq"
for c in bash mv rm cat; do
  src="$(command -v "$c" 2>/dev/null || true)"
  [[ -n "$src" ]] && ln -sf "$src" "$nojq/$c"
done
output="$(env PATH="$nojq" HOME="$h" bash -c "
set -uo pipefail
$strip_fn
strip_docker_creds_store
" 2>&1)"
rc=$?
if [[ "$rc" -eq 0 ]] && printf '%s' "$output" | grep -q 'jq'; then
  pass
else
  fail "jq 不在時の挙動が違う (rc=$rc): $output"
fi

# ── credential.helper の固定と検査 ───────────────────────────────────────────

SB="$(new_workdir)/sb"; mkdir -p "$SB/home"
export HOME="$SB/home"
export GIT_CONFIG_GLOBAL="$SB/home/.gitconfig"
# system スコープに別の供給元を仕込む。これが応答すると、ホスト由来の資格情報が返る。
export GIT_CONFIG_SYSTEM="$SB/system.gitconfig"
printf '[credential]\n\thelper = store\n' > "$GIT_CONFIG_SYSTEM"

repo="$(new_workdir)/r"
mkdir -p "$repo/scripts"
cp "$out/scripts/setup-git-identity.sh" "$out/scripts/load-project-env.sh" "$repo/scripts/"
printf 'GIT_IDENTITY_NAME=Test User\nGIT_IDENTITY_EMAIL=test@example.com\n' > "$repo/.env"
( cd "$repo" && git init -q )

it "適用すると system のヘルパーが実効値から外れる"
( cd "$repo" && bash scripts/setup-git-identity.sh >/dev/null 2>&1 )
# 空文字は一覧のリセット。最後の空要素より後ろだけが実効値になる。
effective="$(cd "$repo" && git config --get-all credential.helper 2>/dev/null \
  | awk '$0 == "" { n = 0; next } { v[++n] = $0 } END { for (i = 1; i <= n; i++) print v[i] }' | tr '\n' '|')"
assert_eq "$effective" "!gh auth git-credential|" "実効ヘルパー"

it "--check が固定を検査する"
co="$(cd "$repo" && bash scripts/setup-git-identity.sh --check 2>&1)"; crc=$?
if [[ "$crc" -eq 0 ]] && printf '%s' "$co" | grep -q '供給元は gh のみ'; then
  pass
else
  fail "--check に供給元の検査が無い (rc=$crc)"
fi

it "--check は固定が崩れた状態を非ゼロで報告する"
# 空文字のリセットを外すと system 側の store が再び応答する。この差を検出できないと、
# 「検査は通るのにホストの資格情報が使われる」状態を見逃す。
( cd "$repo" && git config --global --unset-all credential.helper \
    && git config --global --add credential.helper '!gh auth git-credential' )
co="$(cd "$repo" && bash scripts/setup-git-identity.sh --check 2>&1)"; crc=$?
if [[ "$crc" -ne 0 ]] && printf '%s' "$co" | grep -q 'gh 以外の供給元が残っている'; then
  pass
else
  fail "崩れた固定を検出できない (rc=$crc): $(printf '%s' "$co" | grep -i credential | head -2)"
fi

exit_with_result
