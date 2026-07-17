#!/usr/bin/env bash
# compose 化されたテンプレートの生成物を検証する。
#
# devcontainer.json の "image" 単一コンテナ構成から docker-compose ベース
# （単一サービス app）へ移行した。compose 利用時は feature 側や devcontainer.json の
# mounts が適用されないため、docker socket や AI CLI 用の名前付きボリュームは
# compose.yaml 側で明示しなければならない。この配線が欠けると rebuild 後に
# docker CLI や AI CLI の認証が静かに失われる。

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-compose-config"

for mode in minimal standard full; do
  out="$(new_workdir)/p"
  # run_bootstrap は --mode minimal を先に渡すが、後から渡した --mode が勝つ。
  run_bootstrap "$out" --mode "$mode" >/dev/null 2>&1
  dc="$out/.devcontainer/devcontainer.json"
  compose="$out/.devcontainer/compose.yaml"

  it "$mode: compose.yaml が生成される"
  assert_file_exists "$compose"

  it "$mode: devcontainer.json が compose.yaml を参照する"
  assert_eq "$(jq -r '.dockerComposeFile' "$dc")" "compose.yaml" "dockerComposeFile"

  it "$mode: サービス名は app"
  assert_eq "$(jq -r '.service' "$dc")" "app" "service"

  it "$mode: workspaceFolder がプロジェクト名で解決される"
  assert_eq "$(jq -r '.workspaceFolder' "$dc")" "/workspaces/test" "workspaceFolder"

  it "$mode: image ベース指定は残っていない"
  assert_eq "$(jq -r '.image' "$dc")" "null" "image"

  it "$mode: compose.yaml にプレースホルダが残っていない"
  if grep -qE '__BASE_IMAGE__|__PROJECT_NAME__' "$compose"; then
    fail "プレースホルダが未置換: $(grep -oE '__[A-Z_]+__' "$compose" | sort -u | tr '\n' ' ')"
  else
    pass
  fi

  it "$mode: compose.yaml に docker socket のマウントがある"
  if grep -q '/var/run/docker.sock:/var/run/docker-host.sock' "$compose"; then
    pass
  else
    fail "docker socket マウントが無い"
  fi
done

# ── full 固有: AI CLI ボリュームは compose 側へ移した ─────────────────────────

out="$(new_workdir)/p"
run_bootstrap "$out" --mode full >/dev/null 2>&1
dc="$out/.devcontainer/devcontainer.json"
compose="$out/.devcontainer/compose.yaml"

it "full: devcontainer.json に mounts が残っていない"
assert_eq "$(jq -r '.mounts' "$dc")" "null" "mounts"

it "full: compose.yaml に claude-storage ボリュームがある"
if grep -q 'claude-storage' "$compose"; then pass; else fail "claude-storage が無い"; fi

# ── doctor.sh の compose 配線検査 ─────────────────────────────────────────────

DOCTOR="$PKG_DIR/doctor.sh"
out="$(new_workdir)/p"
run_bootstrap "$out" >/dev/null 2>&1
dc="$out/.devcontainer/devcontainer.json"

it "doctor: compose 配線が検査に通る"
output="$(bash "$DOCTOR" --target-dir "$out" 2>&1)"
if [[ $? -eq 0 ]] && printf '%s' "$output" | grep -q 'compose.yaml exists'; then
  pass
else
  fail "doctor が compose 配線を検証できない"
fi

it "doctor: 絶対パスの dockerComposeFile も検査できる"
abs_compose="$out/.devcontainer/compose.yaml"
jq --arg p "$abs_compose" '.dockerComposeFile = $p' "$dc" > "$dc.tmp" && mv "$dc.tmp" "$dc"
output="$(bash "$DOCTOR" --target-dir "$out" 2>&1)"
if [[ $? -eq 0 ]] && printf '%s' "$output" | grep -q "dockerComposeFile exists: $abs_compose"; then
  pass
else
  fail "絶対パス参照を検査できない"
fi

it "doctor: 参照先 compose が無いと失敗する"
jq '.dockerComposeFile = "compose.yaml"' "$dc" > "$dc.tmp" && mv "$dc.tmp" "$dc"
rm "$out/.devcontainer/compose.yaml"
output="$(bash "$DOCTOR" --target-dir "$out" 2>&1)"
if [[ $? -ne 0 ]] && printf '%s' "$output" | grep -q 'compose.yaml missing'; then
  pass
else
  fail "compose 欠落を検出できない"
fi

it "doctor: 旧 image ベース構成では compose 検査をスキップする（後方互換）"
jq 'del(.dockerComposeFile, .service, .workspaceFolder, .shutdownAction)
    + {image: "mcr.microsoft.com/devcontainers/base:ubuntu"}' \
  "$dc" > "$dc.tmp" && mv "$dc.tmp" "$dc"
output="$(bash "$DOCTOR" --target-dir "$out" 2>&1)"
if [[ $? -eq 0 ]] && ! printf '%s' "$output" | grep -q 'compose'; then
  pass
else
  fail "旧構成で compose 検査が走った、または doctor が失敗した"
fi

# ── 不正なプロジェクト名は生成前に拒否される ──────────────────────────────────

for bad_name in 'a:b' 'a|b' 'a"b'; do
  it "生成物を壊すプロジェクト名は拒否される: $bad_name"
  out="$(new_workdir)/p"
  output="$(run_bootstrap "$out" --project-name "$bad_name" 2>&1)"
  if [[ $? -ne 0 ]] && printf '%s' "$output" | grep -q 'must not contain'; then
    pass
  else
    fail "'$bad_name' が拒否されない"
  fi
done

exit_with_result
