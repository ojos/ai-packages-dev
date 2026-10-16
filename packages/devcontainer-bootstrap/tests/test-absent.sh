#!/usr/bin/env bash
# test-absent.sh — 生成物を意図して置かない記録（bootstrap.sh --absent / --no-absent）と、
# それに関わる --upgrade の振り分け・doctor.sh の診断を検証する（#614）。
#
# 確かめること:
#   - compose.yaml を消して --absent したあと、doctor.sh --strict が 0 で、--upgrade 後も作られない
#   - --no-absent の後の --upgrade で compose.yaml が生成される
#   - 外せない一覧・生成物でないパス・現物があるパスは、--absent が非 0 で止まり ORIGIN を変えない
#   - 生成の引数・--upgrade・他の動作との併用は拒否する
#   - absent: があるのに現物があると doctor が FAIL。外せない一覧のパスの absent: も FAIL
#   - 外せない一覧と README の表が一致する（機械照合）。bootstrap.sh と doctor.sh も一致する
#   - absent: の無い ORIGIN の doctor の結果は変わらない

set -uo pipefail

if [[ -z "${TEST_TMP_ROOT:-}" ]]; then
  TEST_TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dcb-absent-test.XXXXXX")"
  export TEST_TMP_ROOT
  trap 'rm -rf "$TEST_TMP_ROOT"' EXIT
fi
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-absent"

IMG="mcr.microsoft.com/devcontainers/base:noble"
DOCTOR="$PKG_DIR/doctor.sh"
README="$PKG_DIR/README.md"
ORIGIN_REL=".devcontainer/ORIGIN"
TARGET=".devcontainer/compose.yaml"

gen() { # out [args...]
  local out="$1"; shift
  bash "$BOOTSTRAP" --project-name abs --languages node --base-image "$IMG" --output-dir "$out" --playbook-from "$PLAYBOOK_SRC" "$@" >/dev/null 2>&1
}
upgrade() { # out [args...] — 出力は UP_OUT、終了コードは UP_RC
  local out="$1"; shift
  UP_OUT="$(bash "$BOOTSTRAP" --upgrade --output-dir "$out" --playbook-from "$PLAYBOOK_SRC" "$@" 2>&1)"
  UP_RC=$?
}
absent() { # out [args...] — 出力は AB_OUT、終了コードは AB_RC
  local out="$1"; shift
  AB_OUT="$(bash "$BOOTSTRAP" --absent "$@" --output-dir "$out" 2>&1)"
  AB_RC=$?
}
unabsent() { # out [args...]
  local out="$1"; shift
  AB_OUT="$(bash "$BOOTSTRAP" --no-absent "$@" --output-dir "$out" 2>&1)"
  AB_RC=$?
}
doctor_strict() { # out — 終了コードを返す。出力は $TEST_TMP_ROOT/doctor.out
  bash "$DOCTOR" --strict --target-dir "$1" >"$TEST_TMP_ROOT/doctor.out" 2>&1
}

# 実際の利用側と同じ形にする: devcontainer.json はプロジェクト独自の compose ファイルを指し、
# 生成物の compose.yaml は使わない。devcontainer.json の手直しは --accept で取り込み済みにする
# （compose.yaml を指したまま消すのは本物の壊れで、doctor は別の検査で FAIL にする）。
use_own_compose() { # out
  local out="$1" f="$1/.devcontainer/devcontainer.json"
  jq '.dockerComposeFile = "my-compose.yaml"' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  printf 'services: {}\n' > "$out/.devcontainer/my-compose.yaml"
  bash "$BOOTSTRAP" --accept .devcontainer/devcontainer.json --output-dir "$out" >/dev/null 2>&1
}

# ── 外せない一覧の機械照合 ────────────────────────────────────────────────────

impl_list() { # [file]
  local f="${1:-$BOOTSTRAP}"
  ( eval "$(sed -n '/^absent_forbidden_rel_paths() {$/,/^}$/p' "$f")"; absent_forbidden_rel_paths ) | sort -u
}
doctor_list() { # [file]
  local f="${1:-$DOCTOR}"
  sed -n '/^ABSENT_FORBIDDEN_PATHS=(/,/^)/p' "$f" | sed '1d;$d' | sed 's/^ *//' | sort -u
}
doc_list() { # [file]
  local f="${1:-$README}"
  command grep '外せない一覧:' "$f" | sed -n 's/^| `\([^`]*\)` |.*/\1/p' | sort -u
}

it "外せない一覧が空でなく、11 件ある"
if [[ "$(impl_list | wc -l | tr -d ' ')" == "11" ]]; then pass; else fail "$(impl_list | tr '\n' ' ')"; fi

it "bootstrap.sh の外せない一覧と README の表が一致する"
if [[ "$(impl_list)" == "$(doc_list)" ]]; then pass; else fail "実装: $(impl_list | tr '\n' ' ') / README: $(doc_list | tr '\n' ' ')"; fi

it "bootstrap.sh の外せない一覧と doctor.sh の一覧が一致する"
if [[ "$(impl_list)" == "$(doctor_list)" ]]; then pass; else fail "実装: $(impl_list | tr '\n' ' ') / doctor: $(doctor_list | tr '\n' ' ')"; fi

it "README の表から 1 行落とすと不一致を検出する（検査が空振りしていない）"
command grep -v '^| `scripts/confirm-merge-hook.sh` |' "$README" > "$TEST_TMP_ROOT/readme.mut"
if [[ "$(impl_list)" != "$(doc_list "$TEST_TMP_ROOT/readme.mut")" ]]; then pass; else fail "落としたのに一致のまま"; fi

it "doctor.sh の一覧へ 1 件足すと不一致を検出する"
sed 's|^  scripts/confirm-merge-hook.sh$|  scripts/confirm-merge-hook.sh\n  scripts/extra.sh|' "$DOCTOR" > "$TEST_TMP_ROOT/doctor.mut"
if [[ "$(impl_list)" != "$(doctor_list "$TEST_TMP_ROOT/doctor.mut")" ]]; then pass; else fail "足したのに一致のまま"; fi

# ── 対照群: absent: の無い ORIGIN ─────────────────────────────────────────────

out="$(new_workdir)/p"
gen "$out"

it "対照群: 生成直後は doctor.sh --strict が 0 で、absent の報告は出ない"
doctor_strict "$out"; rc=$?
if [[ "$rc" == "0" ]] && ! grep -i 'absent' "$TEST_TMP_ROOT/doctor.out" >/dev/null; then pass; else fail "rc=$rc: $(cat "$TEST_TMP_ROOT/doctor.out")"; fi

it "対照群: absent: の無い ORIGIN で現物を消すと、従来どおり missing で FAIL"
rm -f "$out/$TARGET"
doctor_strict "$out"; rc=$?
if [[ "$rc" != "0" ]] && grep 'recorded in origin but missing' "$TEST_TMP_ROOT/doctor.out" >/dev/null; then pass; else fail "rc=$rc"; fi

it "対照群: absent: の無い ORIGIN での --upgrade は消したファイルを作り直す"
upgrade "$out"
if [[ "$UP_RC" == "0" && -f "$out/$TARGET" && "$UP_OUT" == *"write: $out/$TARGET (new)"* ]] \
  && ! grep '^absent:' "$out/$ORIGIN_REL" >/dev/null; then pass; else fail "rc=$UP_RC $UP_OUT"; fi

# ── --absent → doctor が通り、--upgrade が作らない ────────────────────────────

out="$(new_workdir)/p"
gen "$out"
use_own_compose "$out"
rm -f "$out/$TARGET"

it "--absent --dry-run は ORIGIN を変えず、予定だけを出す"
before="$(cksum < "$out/$ORIGIN_REL")"
absent "$out" "$TARGET" --dry-run
after="$(cksum < "$out/$ORIGIN_REL")"
if [[ "$AB_RC" == "0" && "$before" == "$after" && "$AB_OUT" == *"plan: absent: $TARGET"* ]]; then pass; else fail "rc=$AB_RC $AB_OUT"; fi

it "--absent で ORIGIN へ absent: を書き、hash: の行は変えない"
hashes_before="$(grep '^hash:' "$out/$ORIGIN_REL")"
absent "$out" "$TARGET"
if [[ "$AB_RC" == "0" ]] && grep -Fx "absent:$TARGET=1" "$out/$ORIGIN_REL" >/dev/null \
  && [[ "$hashes_before" == "$(grep '^hash:' "$out/$ORIGIN_REL")" ]]; then pass; else fail "rc=$AB_RC $AB_OUT"; fi

it "--absent のあと、doctor.sh --strict は 0 で終わり、件数を [OK] で報告する"
doctor_strict "$out"; rc=$?
if [[ "$rc" == "0" ]] && grep '\[OK\].*intentionally absent (1 file' "$TEST_TMP_ROOT/doctor.out" >/dev/null \
  && ! grep 'missing' "$TEST_TMP_ROOT/doctor.out" >/dev/null; then pass; else fail "rc=$rc: $(cat "$TEST_TMP_ROOT/doctor.out")"; fi

it "同じパスを重ねて --absent しても absent: は 1 行のまま"
absent "$out" "$TARGET"
if [[ "$AB_RC" == "0" && "$(grep -c "^absent:$TARGET=" "$out/$ORIGIN_REL")" == "1" ]]; then pass; else fail "rc=$AB_RC"; fi

it "--upgrade --dry-run は absent を報告し、作る予定を出さない"
upgrade "$out" --dry-run
if [[ "$UP_RC" == "0" && "$UP_OUT" == *"plan: absent"*"$TARGET"* && "$UP_OUT" != *"plan: create $out/$TARGET"* ]]; then pass; else fail "rc=$UP_RC $UP_OUT"; fi

it "--upgrade は compose.yaml を作らず、absent: と hash: を引き継ぐ"
hash_before="$(grep "^hash:$TARGET=" "$out/$ORIGIN_REL")"
upgrade "$out"
if [[ "$UP_RC" == "0" && ! -e "$out/$TARGET" && "$UP_OUT" == *"absent (recorded as intentionally absent): $out/$TARGET"* ]] \
  && grep -Fx "absent:$TARGET=1" "$out/$ORIGIN_REL" >/dev/null \
  && [[ "$hash_before" == "$(grep "^hash:$TARGET=" "$out/$ORIGIN_REL")" ]]; then pass; else fail "rc=$UP_RC $UP_OUT"; fi

it "--upgrade のあとも doctor.sh --strict は 0 で終わる"
doctor_strict "$out"; rc=$?
if [[ "$rc" == "0" ]]; then pass; else fail "rc=$rc: $(cat "$TEST_TMP_ROOT/doctor.out")"; fi

# ── --no-absent → 次の --upgrade で生成される ─────────────────────────────────

it "--no-absent で absent: を外し、hash: は変えない"
unabsent "$out" "$TARGET"
if [[ "$AB_RC" == "0" ]] && ! grep '^absent:' "$out/$ORIGIN_REL" >/dev/null \
  && [[ "$hash_before" == "$(grep "^hash:$TARGET=" "$out/$ORIGIN_REL")" ]]; then pass; else fail "rc=$AB_RC $AB_OUT"; fi

it "--no-absent のあと、現物が無いと doctor.sh --strict は missing で FAIL（記録と現物が一致しない）"
doctor_strict "$out"; rc=$?
if [[ "$rc" != "0" ]] && grep 'recorded in origin but missing' "$TEST_TMP_ROOT/doctor.out" >/dev/null; then pass; else fail "rc=$rc"; fi

it "--no-absent の後の --upgrade で compose.yaml が生成され、doctor.sh --strict が 0"
upgrade "$out"
doctor_strict "$out"; rc=$?
if [[ "$UP_RC" == "0" && -f "$out/$TARGET" && "$UP_OUT" == *"write: $out/$TARGET (new)"* && "$rc" == "0" ]]; then pass; else fail "up=$UP_RC rc=$rc $UP_OUT"; fi

it "absent: の無いパスを --no-absent に渡すと非 0 で止まり、ORIGIN を変えない"
before="$(cksum < "$out/$ORIGIN_REL")"
unabsent "$out" "$TARGET"
after="$(cksum < "$out/$ORIGIN_REL")"
if [[ "$AB_RC" != "0" && "$before" == "$after" && "$AB_OUT" == *"absent: の記録がありません"* ]]; then pass; else fail "rc=$AB_RC $AB_OUT"; fi

# ── 受け付けない入力は、何も書かずに止まる ───────────────────────────────────

out="$(new_workdir)/p"
gen "$out" --with-claude
before="$(cksum < "$out/$ORIGIN_REL")"

it "外せない一覧のパスは、現物を消していても --absent が非 0 で止まる"
rc_all=0
for rel in $(impl_list); do
  rm -f "$out/$rel"
  absent "$out" "$rel"
  if [[ "$AB_RC" == "0" ]]; then rc_all=1; echo "    受け付けた: $rel"; fi
  # 拒否の理由が「外せない」であること（hash: が無いための拒否で素通りしていない）
  if [[ "$AB_OUT" != *"ゲート・検証・承認の機構"* ]]; then rc_all=1; echo "    理由が違う: $rel"; fi
  # 現物を戻す（次の検査と食い違わせない）
  gen "$out" --with-claude --force
done
after="$(cksum < "$out/$ORIGIN_REL")"
if [[ "$rc_all" == "0" ]]; then pass; else fail "外せない一覧のパスを受け付けた"; fi

# --force で再生成したので ORIGIN を取り直す
before="$(cksum < "$out/$ORIGIN_REL")"

it "外せない一覧のパスの拒否は、理由を出して ORIGIN を変えない"
rm -f "$out/scripts/verify.sh"
absent "$out" scripts/verify.sh
after="$(cksum < "$out/$ORIGIN_REL")"
if [[ "$AB_RC" != "0" && "$before" == "$after" && "$AB_OUT" == *"ゲート・検証・承認の機構"* ]]; then pass; else fail "rc=$AB_RC $AB_OUT"; fi
gen "$out" --with-claude --force

it "生成物でないパス（hash: の記録が無い）は --absent が非 0 で止まる"
before="$(cksum < "$out/$ORIGIN_REL")"
absent "$out" docs/not-generated.md
after="$(cksum < "$out/$ORIGIN_REL")"
if [[ "$AB_RC" != "0" && "$before" == "$after" && "$AB_OUT" == *"生成物ではありません"* ]]; then pass; else fail "rc=$AB_RC $AB_OUT"; fi

it "現物があるパスは --absent が非 0 で止まる"
absent "$out" "$TARGET"
after="$(cksum < "$out/$ORIGIN_REL")"
if [[ "$AB_RC" != "0" && "$before" == "$after" && "$AB_OUT" == *"現物があります"* ]]; then pass; else fail "rc=$AB_RC $AB_OUT"; fi

it "1 つでも拒否されるパスがあれば、有効なパスも書かない"
rm -f "$out/$TARGET"
absent "$out" "$TARGET" scripts/verify.sh
after="$(cksum < "$out/$ORIGIN_REL")"
if [[ "$AB_RC" != "0" && "$before" == "$after" ]] && ! grep '^absent:' "$out/$ORIGIN_REL" >/dev/null; then pass; else fail "rc=$AB_RC"; fi

it "パス無しの --absent / --no-absent は非 0 で止まる"
a_out="$(bash "$BOOTSTRAP" --absent --output-dir "$out" 2>&1)"; a_rc=$?
n_out="$(bash "$BOOTSTRAP" --no-absent --output-dir "$out" 2>&1)"; n_rc=$?
if [[ "$a_rc" != "0" && "$n_rc" != "0" ]]; then pass; else fail "absent=$a_rc no-absent=$n_rc"; fi

it "--absent は生成の引数・--upgrade・--accept・--no-absent と同時に指定できない"
bad=""
for extra in "--languages node" "--project-name x" "--with-aws" "--without-aws" "--force" "--upgrade" "--no-gitignore" "--accept $TARGET" "--no-absent $TARGET" "--second-opinion-engine gemini"; do
  # shellcheck disable=SC2086
  o="$(bash "$BOOTSTRAP" --absent "$TARGET" $extra --output-dir "$out" 2>&1)"; r=$?
  if [[ "$r" == "0" || "$o" != *"同時に指定できません"* ]]; then bad="$bad [$extra rc=$r]"; fi
done
if [[ -z "$bad" && "$before" == "$(cksum < "$out/$ORIGIN_REL")" ]]; then pass; else fail "$bad"; fi

it "--no-absent は生成の引数・--upgrade・--accept と同時に指定できない"
bad=""
for extra in "--languages node" "--upgrade" "--accept $TARGET" "--force"; do
  # shellcheck disable=SC2086
  o="$(bash "$BOOTSTRAP" --no-absent "$TARGET" $extra --output-dir "$out" 2>&1)"; r=$?
  if [[ "$r" == "0" || "$o" != *"同時に指定できません"* ]]; then bad="$bad [$extra rc=$r]"; fi
done
if [[ -z "$bad" ]]; then pass; else fail "$bad"; fi

it "--accept の併用拒否は従来どおり（--absent を足しても同じ文言で止まる）"
o="$(bash "$BOOTSTRAP" --accept "$TARGET" --force --output-dir "$out" 2>&1)"; r=$?
if [[ "$r" != "0" && "$o" == *"--accept は生成の引数や --upgrade と同時に指定できません"* ]]; then pass; else fail "rc=$r $o"; fi

# ── --absent が accepted: / pending: を外す ─────────────────────────────────

it "--absent は同じパスの accepted: / pending: を外す"
printf 'accepted:%s=%064d\npending:%s=1\n' "$TARGET" 0 "$TARGET" >> "$out/$ORIGIN_REL"
absent "$out" "$TARGET"
if [[ "$AB_RC" == "0" ]] && ! grep "^accepted:$TARGET=" "$out/$ORIGIN_REL" >/dev/null \
  && ! grep "^pending:$TARGET=" "$out/$ORIGIN_REL" >/dev/null \
  && grep -Fx "absent:$TARGET=1" "$out/$ORIGIN_REL" >/dev/null; then pass; else fail "rc=$AB_RC $AB_OUT"; fi

# ── doctor の判定 ─────────────────────────────────────────────────────────

it "absent: があるのに現物があると、doctor.sh は FAIL にし、--no-absent を案内する"
printf '# restored by hand\n' > "$out/$TARGET"
doctor_strict "$out"; rc=$?
if [[ "$rc" != "0" ]] && grep 'absent record but file exists' "$TEST_TMP_ROOT/doctor.out" >/dev/null \
  && grep -- '--no-absent' "$TEST_TMP_ROOT/doctor.out" >/dev/null; then pass; else fail "rc=$rc: $(cat "$TEST_TMP_ROOT/doctor.out")"; fi

it "現物があって absent: がある状態の --upgrade は、記録を引き継がず通常どおり扱う"
upgrade "$out"
if ! grep '^absent:' "$out/$ORIGIN_REL" >/dev/null && [[ -f "$out/$TARGET" ]]; then pass; else fail "rc=$UP_RC $UP_OUT"; fi

it "外せない一覧のパスに absent: があると、現物が無くても ORIGIN の破損として FAIL"
out2="$(new_workdir)/p"
gen "$out2"
rm -f "$out2/scripts/verify.sh"
printf 'absent:scripts/verify.sh=1\n' >> "$out2/$ORIGIN_REL"
doctor_strict "$out2"; rc=$?
if [[ "$rc" != "0" ]] && grep 'ORIGIN corrupted: absent record on a gate/verification file' "$TEST_TMP_ROOT/doctor.out" >/dev/null; then pass; else fail "rc=$rc: $(cat "$TEST_TMP_ROOT/doctor.out")"; fi

it "外せない一覧のパスに absent: があって現物もある場合も FAIL"
gen "$out2" --force
printf 'absent:scripts/verify.sh=1\n' >> "$out2/$ORIGIN_REL"
doctor_strict "$out2"; rc=$?
if [[ "$rc" != "0" ]] && grep 'ORIGIN corrupted' "$TEST_TMP_ROOT/doctor.out" >/dev/null; then pass; else fail "rc=$rc"; fi

it "外せない一覧のパスの absent: は、--upgrade が無視して通常どおり生成する"
rm -f "$out2/scripts/verify.sh"
upgrade "$out2"
if [[ -f "$out2/scripts/verify.sh" && -x "$out2/scripts/verify.sh" ]] && ! grep '^absent:' "$out2/$ORIGIN_REL" >/dev/null; then pass; else fail "rc=$UP_RC $UP_OUT"; fi

it "absent: の書式検査: 認識される行として通る（認識できない行にはならない）"
out3="$(new_workdir)/p"
gen "$out3"
printf 'absent:docs/x.md=1\n' >> "$out3/$ORIGIN_REL"
doctor_strict "$out3"; rc=$?
if ! grep '認識できない行' "$TEST_TMP_ROOT/doctor.out" >/dev/null; then pass; else fail "rc=$rc: $(cat "$TEST_TMP_ROOT/doctor.out")"; fi

# ── 静的な構造の検査・hash: の無い absent: ・--force・エラー文 ───────────────

it "静的な構造の検査: .env.example を absent にしても doctor.sh --strict が通る"
out4="$(new_workdir)/p"
gen "$out4"
rm -f "$out4/.env.example"
absent "$out4" .env.example
doctor_strict "$out4"; rc=$?
if [[ "$AB_RC" == "0" && "$rc" == "0" ]] && grep 'intentionally absent' "$TEST_TMP_ROOT/doctor.out" >/dev/null; then pass; else fail "ab=$AB_RC rc=$rc: $(cat "$TEST_TMP_ROOT/doctor.out")"; fi

it "静的な構造の検査: 各スクリプトを absent にしても doctor.sh --strict が通る"
bad=""
for rel in scripts/on-attach.sh scripts/fix-mount-owner.sh scripts/post-rebuild-check.sh scripts/check-no-secrets.sh; do
  rm -f "$out4/$rel"
  absent "$out4" "$rel"
  [[ "$AB_RC" == "0" ]] || bad="$bad [absent $rel]"
done
doctor_strict "$out4"; rc=$?
if [[ -z "$bad" && "$rc" == "0" ]]; then pass; else fail "$bad rc=$rc: $(cat "$TEST_TMP_ROOT/doctor.out")"; fi

it "devcontainer.json が指す compose ファイルが無ければ、absent: があっても doctor.sh は FAIL"
out5="$(new_workdir)/p"
gen "$out5"
rm -f "$out5/$TARGET"
absent "$out5" "$TARGET"
doctor_strict "$out5"; rc=$?
if [[ "$AB_RC" == "0" && "$rc" != "0" ]] && grep 'compose.yaml missing' "$TEST_TMP_ROOT/doctor.out" >/dev/null; then pass; else fail "ab=$AB_RC rc=$rc"; fi

it "doctor: hash: の無い absent: は ORIGIN の不正として FAIL"
printf 'absent:docs/x.md=1\n' >> "$out3/$ORIGIN_REL"
doctor_strict "$out3"; rc=$?
if [[ "$rc" != "0" ]] && grep '生成物でない' "$TEST_TMP_ROOT/doctor.out" >/dev/null; then pass; else fail "rc=$rc"; fi

it "doctor: 値が 1 でない absent: は ORIGIN の不正として FAIL"
out6="$(new_workdir)/p"
gen "$out6"
rm -f "$out6/.env.example"
printf 'absent:.env.example=0\n' >> "$out6/$ORIGIN_REL"
doctor_strict "$out6"; rc=$?
if [[ "$rc" != "0" ]] && grep '値が 1 でない' "$TEST_TMP_ROOT/doctor.out" >/dev/null; then pass; else fail "rc=$rc"; fi

it "--upgrade: hash: の無い absent: は引き継がず、警告して捨てる"
out7="$(new_workdir)/p"
gen "$out7"
printf 'absent:docs/x.md=1\n' >> "$out7/$ORIGIN_REL"
upgrade "$out7"
if [[ "$UP_RC" == "0" && "$UP_OUT" == *"docs/x.md"*"捨てます"* ]] && ! grep '^absent:' "$out7/$ORIGIN_REL" >/dev/null; then pass; else fail "rc=$UP_RC $UP_OUT"; fi

it "--force の生成し直しは absent: を引き継がず、ファイルを作り直す"
out8="$(new_workdir)/p"
# 規範を置く構成の --force は、既存の規範ファイルを温存して ORIGIN を書き直さない既存の挙動があるため、
# 規範なしで生成する。
plain() { bash "$BOOTSTRAP" --project-name abs --languages node --base-image "$IMG" --output-dir "$out8" "$@" >/dev/null 2>&1; }
plain
rm -f "$out8/.env.example"
absent "$out8" .env.example
plain --force
if [[ -f "$out8/.env.example" ]] && ! grep '^absent:' "$out8/$ORIGIN_REL" >/dev/null; then pass; else fail "force で absent が残った"; fi

it "エラー文は呼び出し元の名前（--absent / --no-absent）を出す"
rm -f "$out8/$ORIGIN_REL"
a_out="$(bash "$BOOTSTRAP" --absent .env.example --output-dir "$out8" 2>&1)"
n_out="$(bash "$BOOTSTRAP" --no-absent .env.example --output-dir "$out8" 2>&1)"
if [[ "$a_out" == *"error: --absent:"* && "$n_out" == *"error: --no-absent:"* ]]; then pass; else fail "$a_out / $n_out"; fi

it "親ディレクトリごと消したファイルも --absent できる（.devcontainer 配下ではなく .claude/ で確認）"
out9="$(new_workdir)/p"
gen "$out9" --with-claude
rm -f "$out9/.claude/.gitignore"
rmdir "$out9/.claude" 2>/dev/null || true
absent "$out9" .claude/.gitignore
if [[ "$AB_RC" == "0" ]]; then pass; else fail "rc=$AB_RC $AB_OUT"; fi

exit_with_result
