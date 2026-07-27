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

# mode は廃止。素の生成物（--with-* なし）で共通の compose 配線を検証する。
out="$(new_workdir)/p"
run_bootstrap "$out" >/dev/null 2>&1
dc="$out/.devcontainer/devcontainer.json"
compose="$out/.devcontainer/compose.yaml"

it "compose.yaml が生成される"
assert_file_exists "$compose"

it "devcontainer.json が compose.yaml を参照する"
assert_eq "$(jq -r '.dockerComposeFile' "$dc")" "compose.yaml" "dockerComposeFile"

it "サービス名は app"
assert_eq "$(jq -r '.service' "$dc")" "app" "service"

it "workspaceFolder がプロジェクト名で解決される"
assert_eq "$(jq -r '.workspaceFolder' "$dc")" "/workspaces/test" "workspaceFolder"

it "image ベース指定は残っていない"
assert_eq "$(jq -r '.image' "$dc")" "null" "image"

it "compose.yaml にプレースホルダが残っていない"
if grep -qE '__BASE_IMAGE__|__PROJECT_NAME__|__VOLUME' "$compose"; then
  fail "プレースホルダが未置換: $(grep -oE '__[A-Z_]+__' "$compose" | sort -u | tr '\n' ' ')"
else
  pass
fi

it "compose.yaml に docker socket のマウントがある"
if grep -q '/var/run/docker.sock:/var/run/docker-host.sock' "$compose"; then
  pass
else
  fail "docker socket マウントが無い"
fi

it "docker feature は buildx/compose-switch を標準装備する（旧 standard/full 相当）"
if jq -e '.features["ghcr.io/devcontainers/features/docker-outside-of-docker:1"].installDockerBuildx == true' "$dc" >/dev/null; then
  pass
else
  fail "docker buildx が標準化されていない"
fi

# ── 永続ボリュームの条件配線 ─────────────────────────────────────────────────
#
# gh は github-cli feature が構成に依らず常時入るため、常に永続化する。資格情報を
# ホストから注入しない以上、コンテナ内のログインが唯一の認証手段であり、それが
# rebuild のたびに消えると実用に耐えない。cloud（aws / gcloud）は --with-* 随伴。

# マウント行から volume 名を抽出する（"      - <name>-storage:<dir>"）。
mounted_storages() {
  grep -oE '^ +- [a-z0-9-]+-storage:' "$1" | sed -E 's/^ +- //; s/:$//' | sort | tr '\n' ' '
}

it "素の生成物でも gh-storage が永続化される"
assert_eq "$(mounted_storages "$compose")" "gh-storage " "素の生成物の storage 一覧"

it "素の生成物には AI / cloud 永続ボリュームが無い"
if grep -qE 'claude-storage|gemini-storage|copilot-storage|aws-storage|gcloud-storage' "$compose"; then
  fail "未選択なのに storage ボリュームがある"
else
  pass
fi

it "素の生成物でも volumes セクションが成立する（gh-storage が常時あるため）"
if grep -q '^volumes:' "$compose" && grep -q '^  gh-storage:' "$compose"; then
  pass
else
  fail "トップレベル volumes セクションに gh-storage の定義が無い"
fi

it "素の生成物の compose config が妥当（AI 未選択でも volumes が壊れない）"
if command -v docker >/dev/null 2>&1; then
  if docker compose -f "$compose" config >/dev/null 2>&1; then pass; else fail "docker compose config 失敗"; fi
else
  if grep -q '^volumes:' "$compose"; then pass; else fail "volumes セクションが無い"; fi
fi

out="$(new_workdir)/p"
run_bootstrap "$out" --with-claude >/dev/null 2>&1
dc="$out/.devcontainer/devcontainer.json"
compose="$out/.devcontainer/compose.yaml"

it "--with-claude: devcontainer.json に mounts が残っていない（compose 側で持つ）"
assert_eq "$(jq -r '.mounts' "$dc")" "null" "mounts"

it "--with-claude: claude-storage が gh-storage と併存する"
assert_eq "$(mounted_storages "$compose")" "claude-storage gh-storage " "--with-claude の storage 一覧"

it "--with-claude: compose config が妥当（末尾の volumes セクションが壊れない）"
if command -v docker >/dev/null 2>&1; then
  if docker compose -f "$compose" config >/dev/null 2>&1; then pass; else fail "docker compose config 失敗"; fi
else
  # docker 不在環境では最低限 volumes: セクションの存在で代替
  if grep -q '^volumes:' "$compose"; then pass; else fail "volumes セクションが無い"; fi
fi

# ── cloud 認証の永続化は --with-aws / --with-gcp に随伴する ───────────────────

out="$(new_workdir)/p"
run_bootstrap "$out" --with-aws >/dev/null 2>&1
compose="$out/.devcontainer/compose.yaml"

it "--with-aws: aws-storage が ~/.aws へマウントされる"
if grep -q -- '- aws-storage:/home/vscode/.aws$' "$compose"; then pass; else fail "aws-storage のマウントが無い"; fi

it "--with-aws: gcloud-storage は定義されない"
if grep -q 'gcloud-storage' "$compose"; then fail "gcp 未選択なのに gcloud-storage がある"; else pass; fi

out="$(new_workdir)/p"
run_bootstrap "$out" --with-gcp >/dev/null 2>&1
compose="$out/.devcontainer/compose.yaml"

it "--with-gcp: gcloud-storage が ~/.config/gcloud へマウントされる"
if grep -q -- '- gcloud-storage:/home/vscode/.config/gcloud$' "$compose"; then pass; else fail "gcloud-storage のマウントが無い"; fi

it "--with-gcp: aws-storage は定義されない"
if grep -q 'aws-storage' "$compose"; then fail "aws 未選択なのに aws-storage がある"; else pass; fi

out="$(new_workdir)/p"
run_bootstrap "$out" --with-aws --with-gcp --with-claude --with-gemini --with-copilot >/dev/null 2>&1
compose="$out/.devcontainer/compose.yaml"

it "全装備: マウント行と volumes 定義の集合が一致する"
mounts="$(mounted_storages "$compose")"
defs="$(grep -oE '^  [a-z0-9-]+-storage:' "$compose" | sed -E 's/^  //; s/:$//' | sort | tr '\n' ' ')"
assert_eq "$defs" "$mounts" "volumes 定義とマウントの集合"

it "全装備: compose config が妥当"
if command -v docker >/dev/null 2>&1; then
  if docker compose -f "$compose" config >/dev/null 2>&1; then pass; else fail "docker compose config 失敗"; fi
else
  if grep -q '^volumes:' "$compose"; then pass; else fail "volumes セクションが無い"; fi
fi

# ── post-rebuild-check.sh が実マウントを検査する ─────────────────────────────
#
# 定義しただけでマウントされない状態は、CLI が動くぶん気づきにくく、rebuild のたびに
# 静かにログインが消える形で表面化する。検査行が生成されることを担保する。

PRC="$out/scripts/post-rebuild-check.sh"

it "post-rebuild-check.sh に永続 volume の検査がある"
if grep -q 'check_mounted' "$PRC"; then pass; else fail "check_mounted が無い"; fi

it "post-rebuild-check.sh の検査対象が compose のマウントと一致する"
checked="$(grep -oE '^check_mounted "[^"]+" "[a-z0-9-]+-storage"' "$PRC" \
  | sed -E 's/.*"([a-z0-9-]+-storage)"$/\1/' | sort | tr '\n' ' ')"
assert_eq "$checked" "$(mounted_storages "$compose")" "検査対象の storage 一覧"

it "post-rebuild-check.sh がマウント不在を検出する"
# /proc/mounts に無いディレクトリを検査させ、WARN が出ることを見る。
probe="$(new_workdir)/probe.sh"
{
  sed -n '/^check_mounted() {/,/^}/p' "$PRC"
  echo 'check_mounted "/nonexistent/mount/point" "probe-storage"'
} > "$probe"
probe_out="$(bash "$probe" 2>&1)"
assert_contains "$probe_out" "WARN: probe-storage not mounted" "マウント不在時の出力"

it "post-rebuild-check.sh がマウント済みを検出する"
{
  sed -n '/^check_mounted() {/,/^}/p' "$PRC"
  echo 'check_mounted "/proc" "proc-storage"'
} > "$probe"
probe_out="$(bash "$probe" 2>&1)"
assert_contains "$probe_out" "proc-storage mounted at /proc" "マウント済み時の出力"

it "生成された post-rebuild-check.sh が bash -n を通る"
if bash -n "$PRC" 2>/dev/null; then pass; else fail "syntax error"; fi

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
