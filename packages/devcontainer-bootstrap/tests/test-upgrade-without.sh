#!/usr/bin/env bash
# test-upgrade-without.sh — --without-<名前> で、--upgrade が装備を外せることを検証する（#444）。
#
# 外したフラグは ORIGIN の flags= から消え、そのフラグでだけ生成していたファイルは
# 「手を入れていないものだけ」削除される。手を入れたものは残して報告する。

set -uo pipefail

if [[ -z "${TEST_TMP_ROOT:-}" ]]; then
  TEST_TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dcb-upgrade-without-test.XXXXXX")"
  export TEST_TMP_ROOT
  trap 'rm -rf "$TEST_TMP_ROOT"' EXIT
fi
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-upgrade-without"

IMG="mcr.microsoft.com/devcontainers/base:noble"
ORIGIN_REL=".devcontainer/ORIGIN"
CR_FILES=".github/workflows/copilot-review.yml .github/workflows/review-gate.yml scripts/review-usable.sh scripts/check-review-usable.sh"

gen() { # out [args...]
  local out="$1"; shift
  bash "$BOOTSTRAP" --project-name upg --languages node --base-image "$IMG" --output-dir "$out" --playbook-from "$PLAYBOOK_SRC" "$@" >/dev/null 2>&1
}
upgrade() { # out [args...] — 出力は UP_OUT、終了コードは UP_RC
  local out="$1"; shift
  UP_OUT="$(bash "$BOOTSTRAP" --upgrade --output-dir "$out" --playbook-from "$PLAYBOOK_SRC" "$@" 2>&1)"
  UP_RC=$?
}
# ORIGIN を除いた生成物の一覧（パスと中身）
tree_sans_origin() {
  (cd "$1" && find . -type f ! -path "./$ORIGIN_REL" | sort | while IFS= read -r f; do
    printf '%s %s\n' "$f" "$(cksum < "$f")"
  done)
}
flags_of() { sed -n 's/^flags=//p' "$1/$ORIGIN_REL"; }

# ── 外すと、フラグと未編集のファイルが消える ────────────────────────────────

out="$(new_workdir)/p"
gen "$out" --with-copilot-review --with-claude
ref="$(new_workdir)/ref"
gen "$ref" --with-claude

it "生成直後は 4 ファイルがある"
missing=""; for f in $CR_FILES; do [[ -f "$out/$f" ]] || missing="$missing $f"; done
if [[ -z "$missing" ]]; then pass; else fail "不足:$missing"; fi

it "--dry-run では何も消さず、削除予定を plan: に出す"
upgrade "$out" --without-copilot-review --dry-run
missing=""; planned=""
for f in $CR_FILES; do
  [[ -f "$out/$f" ]] || missing="$missing $f"
  printf '%s' "$UP_OUT" | grep -q "plan: remove .*$f" || planned="$planned $f"
done
if [[ "$UP_RC" == "0" && -z "$missing" && -z "$planned" ]]; then pass; else fail "rc=$UP_RC 消えた:$missing 予定に無い:$planned"; fi

it "--dry-run は ORIGIN の flags= も変えない"
assert_eq "$(flags_of "$out")" "claude,copilot-review"

it "--upgrade --without-copilot-review で ORIGIN の flags= から外れる"
upgrade "$out" --without-copilot-review
assert_eq "$(flags_of "$out")" "claude"

it "未編集の 4 ファイルが消える"
left=""; for f in $CR_FILES; do [[ -e "$out/$f" ]] && left="$left $f"; done
if [[ "$UP_RC" == "0" && -z "$left" ]]; then pass; else fail "rc=$UP_RC 残り:$left"; fi

it "生成物がフラグ無しの新規生成と ORIGIN 以外で一致する"
if [[ "$(tree_sans_origin "$out")" == "$(tree_sans_origin "$ref")" ]]; then pass; else fail "差分あり"; fi

it "次の --upgrade --dry-run の対象に 4 ファイルが出ない"
upgrade "$out" --dry-run
hit=""; for f in $CR_FILES; do printf '%s' "$UP_OUT" | grep -q "$f" && hit="$hit $f"; done
if [[ "$UP_RC" == "0" && -z "$hit" ]]; then pass; else fail "rc=$UP_RC 出た:$hit"; fi

it "逆向き（あとから --with-copilot-review を足す）も通り、4 ファイルが戻る"
upgrade "$out" --with-copilot-review
back=""; for f in $CR_FILES; do [[ -f "$out/$f" ]] || back="$back $f"; done
if [[ "$UP_RC" == "0" && -z "$back" && "$(flags_of "$out")" == "claude,copilot-review" ]]; then pass; else fail "rc=$UP_RC 不足:$back"; fi

# ── 手を入れたものは残す ─────────────────────────────────────────────────────

out="$(new_workdir)/p"
gen "$out" --with-copilot-review
echo "# my edit" >> "$out/scripts/review-usable.sh"
upgrade "$out" --without-copilot-review

it "手を入れたファイルは残り、残したことを報告する"
if [[ -f "$out/scripts/review-usable.sh" ]] && grep -q 'my edit' "$out/scripts/review-usable.sh" \
   && printf '%s' "$UP_OUT" | grep -q 'keep (modified, no longer generated).*scripts/review-usable.sh'; then pass; else fail "rc=$UP_RC"; fi

it "手を入れていない残りの 3 ファイルは消える"
left=""; for f in .github/workflows/copilot-review.yml .github/workflows/review-gate.yml scripts/check-review-usable.sh; do [[ -e "$out/$f" ]] && left="$left $f"; done
if [[ -z "$left" ]]; then pass; else fail "残り:$left"; fi

# ── --without-playbook と併せて渡しても、フラグ由来のファイルは消える ──────────

it "--without-copilot-review --without-playbook を併せて渡しても、4 ファイルは消える"
out="$(new_workdir)/p"
gen "$out" --with-copilot-review
upgrade "$out" --without-copilot-review --without-playbook
left=""; for f in $CR_FILES; do [[ -e "$out/$f" ]] && left="$left $f"; done
if [[ "$UP_RC" == "0" && -z "$left" ]]; then pass; else fail "rc=$UP_RC 残り:$left"; fi

# ── 外した操作の対象外のファイルは、従来どおり消さない ──────────────────────

it "外していないフラグで生成されるファイルは、--without の対象外として残る"
out="$(new_workdir)/p"
gen "$out" --with-copilot-review --with-claude
upgrade "$out" --without-copilot-review
if [[ -f "$out/.claude/skills/land/SKILL.md" && -f "$out/scripts/second-opinion-review.sh" ]]; then pass; else fail "巻き込んで消えた"; fi

# ── 引数の検査 ───────────────────────────────────────────────────────────────

it "--with-x と --without-x の同時指定は、何も書かずエラーで止まる"
out="$(new_workdir)/p"
bash "$BOOTSTRAP" --project-name upg --languages node --base-image "$IMG" --output-dir "$out" --with-aws --without-aws >/dev/null 2>"$out.err"
rc=$?
if [[ "$rc" == "1" && ! -e "$out" ]] && grep -q -- '--without-aws' "$out.err"; then pass; else fail "rc=$rc"; fi

it "--upgrade でも同時指定はエラーで止まり、ファイルを消さない"
out="$(new_workdir)/p"
gen "$out" --with-copilot-review
upgrade "$out" --with-copilot-review --without-copilot-review
if [[ "$UP_RC" == "1" && -f "$out/.github/workflows/review-gate.yml" ]]; then pass; else fail "rc=$UP_RC"; fi

it "--upgrade 以外の --without-<名前> は受け付け、付けないのと同じになる"
out="$(new_workdir)/p"
ref="$(new_workdir)/ref"
bash "$BOOTSTRAP" --project-name upg --languages node --base-image "$IMG" --output-dir "$out" --playbook-from "$PLAYBOOK_SRC" --without-copilot-review >/dev/null 2>&1
rc=$?
gen "$ref"
if [[ "$rc" == "0" && "$(tree_sans_origin "$out")" == "$(tree_sans_origin "$ref")" ]]; then pass; else fail "rc=$rc"; fi

# ── 削除候補の親が出力先の外を指すリンクなら、何も書かずに止まる（#453） ────

# 出力先の中の全ファイルとリンク（パスと中身。リンクは先を含めず印だけ）
snapshot_all() {
  (cd "$1" && find . \( -type f -o -type l \) | sort | while IFS= read -r f; do
    if [[ -L "$f" ]]; then printf '%s link\n' "$f"; else printf '%s %s\n' "$f" "$(cksum < "$f")"; fi
  done)
}

for mode in real dry-run; do
  it "削除候補の親が外を指すリンクなら、--upgrade --without-claude は何も書かず終了コード 1（$mode）"
  w="$(new_workdir)"
  out="$w/p"
  gen "$out" --with-claude
  # 古い版の写し（更新の対象）を 1 つ作る。事前検査が無ければ、これが先に更新される
  echo "# old version" >> "$out/scripts/on-attach.sh"
  newh="$(dcb_file_sha256_for_test "$out/scripts/on-attach.sh")"
  sed "s|^hash:scripts/on-attach.sh=.*|hash:scripts/on-attach.sh=$newh|" "$out/$ORIGIN_REL" > "$out/$ORIGIN_REL.tmp" && mv "$out/$ORIGIN_REL.tmp" "$out/$ORIGIN_REL"
  mv "$out/.claude" "$w/outside"
  ln -s "$w/outside" "$out/.claude"
  before="$(snapshot_all "$out")"; outside_before="$(snapshot_all "$w/outside")"
  if [[ "$mode" == "dry-run" ]]; then upgrade "$out" --without-claude --dry-run; else upgrade "$out" --without-claude; fi
  after="$(snapshot_all "$out")"
  if [[ "$UP_RC" == "1" && "$after" == "$before" && "$(snapshot_all "$w/outside")" == "$outside_before" ]] \
     && printf '%s' "$UP_OUT" | grep -q '出力先の外を指しています'; then pass; else fail "rc=$UP_RC 変化:$(diff <(echo "$before") <(echo "$after") | head -5)"; fi
done

it "--with-* の全フラグに対になる --without-* がある"
miss=""
for n in $(grep -o -- '--with-[a-z-]*)' "$BOOTSTRAP" | sed 's/^--with-//; s/)$//' | sort -u); do
  [[ "$n" == "playbook" ]] && continue
  grep -q -- "--without-$n)" "$BOOTSTRAP" || miss="$miss $n"
done
if [[ -z "$miss" ]]; then pass; else fail "不足:$miss"; fi

exit_with_result
