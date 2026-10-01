#!/usr/bin/env bash
# test-base-image.sh — 生成物のベースイメージが浮動タグでないことを検査する。
#
# 2026-09-10、mcr.microsoft.com/devcontainers/base:ubuntu が指す先が無告知で
# 26.04 へ進んだ。26.04 には apt-key が無く、--with-gcp が入れる
# google-cloud-cli feature の install.sh が exit 127 で落ちた（古いイメージ
# キャッシュがある環境では表に出ず、新しくビルドした環境だけが落ちる）。
# select_base_image() の候補を版の名前（コードネーム）へ固定したのはこのためで、
# 本テストはその固定が崩れていないことを機械で担保する。
#
# 判定は特定のイメージ名（mcr.microsoft.com/devcontainers/base 等）に結びつけず、
# タグの「形」だけで行う。浮動タグとみなすのは次の 4 形:
#   タグ無し（暗黙の latest）/ latest / ubuntu / debian
# これらはいずれも「どの版を指すか」が時間とともに動く名前で、版の名前
# （noble・bookworm のような固有のコードネーム）ではない。
#
# --base-image で明示した値は対象外（scope.out）。利用者が自分の判断で浮動タグを
# 指定した場合、それは本検査が守る不変条件の対象ではない。

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-base-image"

# compose.yaml の image: 行から値を取り出し、末尾のタグ部分だけを返す。
# タグが無ければ空文字を返す（Docker の既定は暗黙の :latest だが、ここでは
# 「タグ無し」と「明示の latest」を別々に検出できるよう空文字のまま返す）。
image_tag_of() {
  local compose="$1" image last_segment
  image="$(grep -m1 '^\s*image:' "$compose" | sed -E 's/^\s*image:\s*//')"
  last_segment="${image##*/}"
  if [[ "$last_segment" == *:* ]]; then
    printf '%s' "${last_segment##*:}"
  else
    printf ''
  fi
}

# 浮動タグの判定。タグの文字列だけを見る（イメージ名には依らない）。
is_floating_tag() {
  case "$1" in
    ''|latest|ubuntu|debian) return 0 ;;
    *) return 1 ;;
  esac
}

it "素の生成物（--base-image 未指定）のベースイメージが浮動タグでない"
out="$(new_workdir)/p"
run_bootstrap "$out" >/dev/null 2>&1
tag="$(image_tag_of "$out/.devcontainer/compose.yaml")"
if [[ -n "$tag" ]] && ! is_floating_tag "$tag"; then
  pass
else
  fail "ベースイメージのタグが浮動タグの形: '$tag'"
fi

it "--with-gcp を足しても自動判定のベースイメージは変わらない"
out="$(new_workdir)/p"
run_bootstrap "$out" --with-gcp >/dev/null 2>&1
tag="$(image_tag_of "$out/.devcontainer/compose.yaml")"
if [[ -n "$tag" ]] && ! is_floating_tag "$tag"; then
  pass
else
  fail "ベースイメージのタグが浮動タグの形: '$tag'"
fi

# ── --base-image の明示指定は対象外（scope.out） ─────────────────────────────
#
# 利用者が明示した値をそのまま尊重することが select_base_image() の契約。
# ここで浮動タグを指定した生成物まで本検査の対象に含めると、利用者の明示指定を
# 上書きしない契約と衝突する。対象外であることそのものを検査する。

it "--base-image で浮動タグを明示した場合はそのまま尊重される（検査対象外）"
out="$(new_workdir)/p"
run_bootstrap "$out" --base-image mcr.microsoft.com/devcontainers/base:ubuntu >/dev/null 2>&1
compose="$out/.devcontainer/compose.yaml"
if grep -q 'image: mcr.microsoft.com/devcontainers/base:ubuntu' "$compose"; then
  pass
else
  fail "--base-image の明示指定が反映されていない"
fi

exit_with_result
