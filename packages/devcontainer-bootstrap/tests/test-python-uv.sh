#!/usr/bin/env bash
# python 選択時の uv 同梱を検証する。
#
# uv には Astral 公式の devcontainer feature が無いため、既存の python feature
# （ghcr.io/devcontainers/features/python:1）の toolsToInstall（pipx 導入のツール列）
# に uv を追記する方式を採る。ここでは python 選択/非選択の両ケースで生成される
# devcontainer.json を検証し、次を守る。
#   - python 選択時: python feature の options に installTools:true と、
#     toolsToInstall へ uv が含まれる。
#   - python 選択時: toolsToInstall は既定ツール群を維持する（uv 追記で既定が
#     回帰していない）。
#   - python 非選択時: python feature も uv も現れない。
#
# ネットワークには出ない。生成物の JSON を jq で検査するだけ。
#
# bash 3.2 互換を維持する（連想配列・mapfile・${var^^} を使わない）。

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-python-uv"

PY_FEATURE='ghcr.io/devcontainers/features/python:1'

# ── python 選択時: uv が toolsToInstall に入る ────────────────────────────────

it "python 選択で python feature に installTools:true が入る"
out="$(new_workdir)/p"
run_bootstrap "$out" --languages python >/dev/null 2>&1
dc="$out/.devcontainer/devcontainer.json"
if jq -e --arg f "$PY_FEATURE" '.features[$f].installTools == true' "$dc" >/dev/null; then
  pass
else
  fail "installTools:true が無い: $(jq --arg f "$PY_FEATURE" '.features[$f]' "$dc")"
fi

it "python 選択で toolsToInstall に uv が含まれる"
out="$(new_workdir)/p"
run_bootstrap "$out" --languages python >/dev/null 2>&1
dc="$out/.devcontainer/devcontainer.json"
# toolsToInstall はカンマ区切り文字列。前後の要素と衝突しない語境界で uv を探す。
if jq -e --arg f "$PY_FEATURE" '
      (.features[$f].toolsToInstall // "")
      | split(",") | map(gsub("^ +| +$";"")) | index("uv")' "$dc" >/dev/null; then
  pass
else
  fail "toolsToInstall に uv が無い: $(jq -r --arg f "$PY_FEATURE" '.features[$f].toolsToInstall' "$dc")"
fi

it "python 選択で既定ツール群が回帰していない（uv 追記で置換していない）"
out="$(new_workdir)/p"
run_bootstrap "$out" --languages python >/dev/null 2>&1
dc="$out/.devcontainer/devcontainer.json"
missing=""
for t in flake8 black mypy pytest pylint; do
  if ! jq -e --arg f "$PY_FEATURE" --arg t "$t" '
        (.features[$f].toolsToInstall // "")
        | split(",") | map(gsub("^ +| +$";"")) | index($t)' "$dc" >/dev/null; then
    missing="$missing $t"
  fi
done
if [[ -z "$missing" ]]; then pass; else fail "既定ツールが欠落:$missing"; fi

it "生成された devcontainer.json は妥当な JSON（python 選択時）"
out="$(new_workdir)/p"
run_bootstrap "$out" --languages python,node,go >/dev/null 2>&1
if jq -e . "$out/.devcontainer/devcontainer.json" >/dev/null 2>&1; then pass; else fail "JSON として不正"; fi

# ── python 非選択時: python feature も uv も現れない ─────────────────────────

it "python 非選択（node のみ）では python feature が無い"
out="$(new_workdir)/p"
run_bootstrap "$out" --languages node >/dev/null 2>&1
dc="$out/.devcontainer/devcontainer.json"
if jq -e --arg f "$PY_FEATURE" '.features | has($f)' "$dc" >/dev/null; then
  fail "非選択なのに python feature がある"
else
  pass
fi

it "python 非選択（node のみ）では uv が devcontainer.json に現れない"
out="$(new_workdir)/p"
run_bootstrap "$out" --languages node >/dev/null 2>&1
dc="$out/.devcontainer/devcontainer.json"
if grep -q 'uv' "$dc"; then fail "非選択なのに uv が現れる: $(grep -n uv "$dc" | head -1)"; else pass; fi

it "python 非選択時は __IF_RUNTIME_PYTHON__ プレースホルダが残留しない"
out="$(new_workdir)/p"
run_bootstrap "$out" --languages node >/dev/null 2>&1
if grep -q '__IF_RUNTIME_PYTHON__' "$out/.devcontainer/devcontainer.json"; then
  fail "未置換プレースホルダ __IF_RUNTIME_PYTHON__ が残っている"
else
  pass
fi

# ── 他言語 feature の options は素のまま（python 特別扱いの越境がない）───────

it "python と併選した go feature は options を持たない（{}）"
out="$(new_workdir)/p"
run_bootstrap "$out" --languages python,go >/dev/null 2>&1
dc="$out/.devcontainer/devcontainer.json"
if jq -e '.features["ghcr.io/devcontainers/features/go:1"] == {}' "$dc" >/dev/null; then
  pass
else
  fail "go feature に想定外の options が付いた: $(jq '.features["ghcr.io/devcontainers/features/go:1"]' "$dc")"
fi

exit_with_result
