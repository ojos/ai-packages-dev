#!/usr/bin/env bash
# test-symlink-rerun.sh — 従来の再実行の経路（--upgrade なし・--force・規範の配置）が、
# 生成先のシンボリックリンクをたどって出力先の外へ書かないことを検証する（#418）。
#
# 生成先に「出力先の外を指す切れたリンク」と「有効なリンク」を置いて実行し、
#   - 出力先の外のファイルが作られも書き換えられもしない（モードも変えない）
#   - 既定（skip）ではリンクが温存される
#   - --force / --playbook-conflict-policy overwrite ではリンクが通常ファイルに置き換わる
#   - 親ディレクトリが出力先の外を指すときは、何も書かずに exit 1 で止まる
# を確かめる。

# shellcheck disable=SC2086,SC2012,SC1091  # 相対パスの一覧は意図して単語分割する
set -uo pipefail

if [[ -z "${TEST_TMP_ROOT:-}" ]]; then
  TEST_TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dcb-symlink-rerun-test.XXXXXX")"
  export TEST_TMP_ROOT
  trap 'rm -rf "$TEST_TMP_ROOT"' EXIT
fi
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-symlink-rerun"

IMG="mcr.microsoft.com/devcontainers/base:noble"
mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

# DCB 自身のテンプレート（write_file。*.json と非 json、ORIGIN）と、
# 規範経由のファイル（apply_file_with_policy。実行体を含む）。.gitignore は管理セクション。
DCB_RELS=".devcontainer/devcontainer.json scripts/verify.sh .devcontainer/ORIGIN"
PB_RELS=".ai-playbook/shared-ai-rules.md .ai-playbook/VERSION CLAUDE.md scripts/second-opinion-review.sh"
ALL_RELS="$DCB_RELS $PB_RELS .gitignore"
N_ALL="$(echo $ALL_RELS | wc -w | tr -d ' ')"

run() { # out [args...] — 出力は RUN_OUT、終了コードは RUN_RC
  local out="$1"; shift
  RUN_OUT="$(bash "$BOOTSTRAP" --project-name sl --languages node --base-image "$IMG" \
    --with-claude --playbook-from "$PLAYBOOK_SRC" --output-dir "$out" "$@" 2>&1)"
  RUN_RC=$?
}

# 出力先 $1 の中の各生成先へリンクを置く。kind=broken|valid。リンク先は外 $2 に平らに置く。
# 有効なリンクの先は、モード 640 の既知の中身。
plant_links() {
  local out="$1" outside="$2" kind="$3" rel flat
  for rel in $ALL_RELS; do
    flat="$(printf '%s' "$rel" | tr '/' '_')"
    mkdir -p "$(dirname "$out/$rel")"
    rm -f "$out/$rel" "$outside/$flat"
    if [[ "$kind" == "valid" ]]; then
      echo "KEEP" > "$outside/$flat"
      chmod 640 "$outside/$flat"
    elif [[ "$kind" == "dir" ]]; then
      mkdir "$outside/$flat"
      echo "KEEP" > "$outside/$flat/s"
      chmod 750 "$outside/$flat"
    fi
    ln -s "$outside/$flat" "$out/$rel"
  done
}

# 外が無傷か: broken なら何も作られていない。valid なら中身とモードが元のまま。
outside_intact() { # outside kind
  local outside="$1" kind="$2" rel flat want=0
  for rel in $ALL_RELS; do
    flat="$(printf '%s' "$rel" | tr '/' '_')"
    if [[ "$kind" == "broken" ]]; then
      [[ ! -e "$outside/$flat" && ! -L "$outside/$flat" ]] || { echo "$flat が作られた"; return 1; }
    elif [[ "$kind" == "dir" ]]; then
      [[ -d "$outside/$flat" && "$(ls -A "$outside/$flat")" == "s" && "$(cat "$outside/$flat/s")" == "KEEP" \
        && "$(mode_of "$outside/$flat")" == "750" ]] || { echo "$flat（ディレクトリ）が変わった"; return 1; }
    else
      [[ "$(cat "$outside/$flat")" == "KEEP" && "$(mode_of "$outside/$flat")" == "640" ]] \
        || { echo "$flat が変わった"; return 1; }
    fi
  done
  [[ "$kind" != "broken" ]] && want="$N_ALL"
  [[ "$(ls -A "$outside" | wc -l | tr -d ' ')" == "$want" ]] || { echo "外のファイル数が違う: $(ls -A "$outside")"; return 1; }
  return 0
}

# 指定した相対パス群のすべてが L=リンクのまま / R=通常ファイルに置き換わっている。
all_state() { # out state(L|R) rels...
  local out="$1" state="$2" rel; shift 2
  for rel in "$@"; do
    if [[ "$state" == "L" ]]; then
      [[ -L "$out/$rel" ]] || { echo "$rel がリンクでない"; return 1; }
    else
      [[ -f "$out/$rel" && ! -L "$out/$rel" ]] || { echo "$rel が通常ファイルでない"; return 1; }
    fi
  done
  return 0
}

for kind in broken valid dir; do
  it "[$kind] 既定の再実行: リンクを温存し、外へ書かない"
  w="$(new_workdir)"; out="$w/p"; outside="$w/outside"; mkdir -p "$outside"
  plant_links "$out" "$outside" "$kind"
  run "$out"
  msg="$(outside_intact "$outside" "$kind")" || true
  st="$(all_state "$out" L $ALL_RELS)" || true
  if [[ "$RUN_RC" == "0" && -z "$msg" && -z "$st" ]] && printf '%s' "$RUN_OUT" | grep -q 'skip (exists): .*devcontainer.json'; then
    pass
  else fail "rc=$RUN_RC msg=$msg st=$st"; fi

  it "[$kind] --force: DCB のテンプレートはリンクが通常ファイルになり、外は無傷"
  w="$(new_workdir)"; out="$w/p"; outside="$w/outside"; mkdir -p "$outside"
  plant_links "$out" "$outside" "$kind"
  run "$out" --force
  msg="$(outside_intact "$outside" "$kind")" || true
  # ORIGIN は、温存した規範経由のファイルがあると「由来を保証できない」ため記録されず、
  # リンクのまま残る（既存の設計）。
  st="$(all_state "$out" R .devcontainer/devcontainer.json scripts/verify.sh .gitignore)" || true
  st2="$(all_state "$out" L $PB_RELS .devcontainer/ORIGIN)" || true
  if [[ "$RUN_RC" == "0" && -z "$msg" && -z "$st" && -z "$st2" ]] && jq -e . "$out/.devcontainer/devcontainer.json" >/dev/null; then
    pass
  else fail "rc=$RUN_RC msg=$msg st=$st st2=$st2"; fi

  it "[$kind] --playbook-conflict-policy overwrite: 規範経由はリンクが通常ファイルになり、外は無傷"
  w="$(new_workdir)"; out="$w/p"; outside="$w/outside"; mkdir -p "$outside"
  plant_links "$out" "$outside" "$kind"
  run "$out" --playbook-conflict-policy overwrite
  msg="$(outside_intact "$outside" "$kind")" || true
  st="$(all_state "$out" R $PB_RELS)" || true
  st2="$(all_state "$out" L $DCB_RELS .gitignore)" || true
  if [[ "$RUN_RC" == "0" && -z "$msg" && -z "$st" && -z "$st2" ]]; then
    pass
  else fail "rc=$RUN_RC msg=$msg st=$st st2=$st2"; fi

  it "[$kind] --force と overwrite の併用: すべて置き換わり、外は無傷"
  w="$(new_workdir)"; out="$w/p"; outside="$w/outside"; mkdir -p "$outside"
  plant_links "$out" "$outside" "$kind"
  run "$out" --force --playbook-conflict-policy overwrite
  msg="$(outside_intact "$outside" "$kind")" || true
  st="$(all_state "$out" R $ALL_RELS)" || true
  if [[ -z "$msg" && -z "$st" && "$RUN_RC" == "0" ]]; then pass; else fail "rc=$RUN_RC msg=$msg st=$st"; fi
done

it "非 json のテンプレート: --force でリンクを置き換え、リンク先へ書かない"
w="$(new_workdir)"; out="$w/p"; outside="$w/outside"; mkdir -p "$outside" "$out/scripts"
echo "KEEP" > "$outside/v.sh"
ln -s "$outside/v.sh" "$out/scripts/verify.sh"
run "$out" --force
if [[ "$RUN_RC" == "0" && "$(cat "$outside/v.sh")" == "KEEP" && -f "$out/scripts/verify.sh" && ! -L "$out/scripts/verify.sh" ]]; then pass; else fail "rc=$RUN_RC"; fi

# 親ディレクトリが出力先の外を指す: 何も書かずに止まる。
for opt in "" "--force" "--playbook-conflict-policy overwrite"; do
  for parent in .devcontainer scripts .ai-playbook .github; do
    it "親ディレクトリ($parent)が外を指す [${opt:-既定}]: exit 1 で止まり、外は空のまま"
    w="$(new_workdir)"; out="$w/p"; outside="$w/outside"; mkdir -p "$outside" "$out"
    ln -s "$outside" "$out/$parent"
    # shellcheck disable=SC2086
    run "$out" $opt
    if [[ "$RUN_RC" == "1" && -z "$(ls -A "$outside")" ]] && printf '%s' "$RUN_OUT" | grep -q '出力先の外'; then
      pass
    else fail "rc=$RUN_RC 外: $(ls -A "$outside")"; fi
  done
done

# 外を指す親が「後に並ぶ」生成先にあるとき、先に並ぶ生成先にも何も書かれない。
# .github は規範経由のファイル（後段）の親。.devcontainer などは先に生成される。
for opt in "" "--force" "--dry-run" "--playbook-conflict-policy overwrite"; do
  it "後段の生成先(.github)の親が外を指す [${opt:-既定}]: 先の生成先にも何も書かず exit 1"
  w="$(new_workdir)"; out="$w/p"; outside="$w/outside"; mkdir -p "$outside" "$out"
  ln -s "$outside" "$out/.github"
  # shellcheck disable=SC2086
  run "$out" $opt
  rest="$(find "$out" -mindepth 1 ! -name .github | wc -l | tr -d ' ')"
  if [[ "$RUN_RC" == "1" && "$rest" == "0" && -z "$(ls -A "$outside")" ]]; then pass; else fail "rc=$RUN_RC 出力先に残った数=$rest"; fi
done

it "--upgrade でも前検査: 親が外を指すなら、先の生成先を更新せず exit 1"
w="$(new_workdir)"; out="$w/p"; outside="$w/outside"; mkdir -p "$outside"
run "$out"
echo "# mine" >> "$out/scripts/verify.sh"
rm -f "$out/.github/project-ai-rules.md"
rm -rf "$out/.github"; ln -s "$outside" "$out/.github"
before="$(cat "$out/.devcontainer/devcontainer.json")"
bash "$BOOTSTRAP" --upgrade --output-dir "$out" --playbook-from "$PLAYBOOK_SRC" >/dev/null 2>&1; UP_RC=$?
if [[ "$UP_RC" == "1" && -z "$(ls -A "$outside")" && ! -e "$out/scripts/verify.sh.dcb-new" ]] \
  && [[ "$before" == "$(cat "$out/.devcontainer/devcontainer.json")" ]]; then pass; else fail "rc=$UP_RC"; fi

it "親ディレクトリが外を指す（外にファイルあり）: 外のファイルが無傷"
w="$(new_workdir)"; out="$w/p"; outside="$w/outside"; mkdir -p "$outside" "$out"
echo "orig" > "$outside/verify.sh"
ln -s "$outside" "$out/scripts"
run "$out" --force
if [[ "$RUN_RC" == "1" && "$(cat "$outside/verify.sh")" == "orig" && "$(ls "$outside")" == "verify.sh" ]]; then pass; else fail "rc=$RUN_RC"; fi

it "通常ファイルの overwrite は、親ディレクトリに書き込み権限が無くても成功する"
if [[ "$(id -u)" == "0" ]]; then
  echo "  skip (root で走るため、権限の検査はできない)"
  pass
else
  w="$(new_workdir)"; out="$w/p"
  run "$out"
  echo "# edit" >> "$out/.ai-playbook/shared-ai-rules.md"
  chmod 640 "$out/.ai-playbook/shared-ai-rules.md"
  chmod a-w "$out/.ai-playbook"
  run "$out" --playbook-conflict-policy overwrite
  chmod u+w "$out/.ai-playbook"
  if [[ "$RUN_RC" == "0" ]] && ! grep -q '# edit' "$out/.ai-playbook/shared-ai-rules.md" \
    && [[ "$(mode_of "$out/.ai-playbook/shared-ai-rules.md")" == "640" ]]; then pass; else fail "rc=$RUN_RC"; fi
fi

it "ハードリンクの生成先を overwrite / --force すると、もう一方のパスにも反映される"
w="$(new_workdir)"; out="$w/p"
run "$out"
ln "$out/.ai-playbook/shared-ai-rules.md" "$w/hl-rules"
ln "$out/.devcontainer/devcontainer.json" "$w/hl-json"
echo "# edit" >> "$out/.ai-playbook/shared-ai-rules.md"
echo "{}" > "$out/.devcontainer/devcontainer.json"
run "$out" --force --playbook-conflict-policy overwrite
if [[ "$RUN_RC" == "0" ]] && ! grep -q '# edit' "$w/hl-rules" && cmp -s "$w/hl-rules" "$out/.ai-playbook/shared-ai-rules.md" \
  && cmp -s "$w/hl-json" "$out/.devcontainer/devcontainer.json" && grep -q '"name"' "$w/hl-json"; then pass; else fail "rc=$RUN_RC"; fi

it "リンクでない通常の生成先: skip で温存・--force で上書き（挙動は変えない）"
w="$(new_workdir)"; out="$w/p"
run "$out"
echo "# edit" >> "$out/scripts/verify.sh"
run "$out"
kept="$(grep -c '# edit' "$out/scripts/verify.sh")"
run "$out" --force
if [[ "$RUN_RC" == "0" && "$kept" == "1" ]] && ! grep -q '# edit' "$out/scripts/verify.sh"; then pass; else fail "kept=$kept"; fi

exit_with_result
