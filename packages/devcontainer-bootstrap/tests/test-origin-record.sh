#!/usr/bin/env bash
# test-origin-record.sh — 生成物の由来の記録（.devcontainer/ORIGIN）を検証する（#321）。
#
# 記録には「DCB の版」「使った --with-* フラグ」「各生成物のハッシュ」を持たせ、
# doctor.sh がネットワークを使わずに乖離を診断できるようにする（issue #321
# 「方針決定」）。ここでは bootstrap.sh 側の生成責務を検証する。診断側
# （doctor.sh）は test-doctor-origin.sh が担う。

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-origin-record"

DOCTOR="$PKG_DIR/doctor.sh"
ORIGIN_REL="/.devcontainer/ORIGIN"

# ── 生成直後の記録 ────────────────────────────────────────────────────────────

it "生成直後に .devcontainer/ORIGIN が置かれる"
out="$(new_workdir)/p"
run_bootstrap "$out" --with-aws >/dev/null 2>&1
assert_file_exists "$out$ORIGIN_REL"

it "記録は機械可読な key=value 形式で version を持つ"
origin="$out$ORIGIN_REL"
if grep -qE '^version=v[0-9]+\.[0-9]+\.[0-9]+$' "$origin"; then pass; else fail "version= 行が期待した形式でない: $(grep '^version=' "$origin")"; fi

it "記録は使った --with-* フラグの一覧を持つ"
assert_eq "$(sed -n 's/^flags=//p' "$origin")" "aws" "flags="

it "記録は各生成物のハッシュを持つ（scripts/verify.sh を例に、実ハッシュと一致する）"
recorded="$(sed -n 's|^hash:scripts/verify\.sh=||p' "$origin")"
actual="$(dcb_file_sha256_for_test "$out/scripts/verify.sh")"
assert_eq "$recorded" "$actual" "scripts/verify.sh のハッシュ"

it "記録は .ai-playbook/** のハッシュを持たない（あちらは VERSION が別に担う）"
if grep -q '^hash:\.ai-playbook/' "$origin"; then
  fail ".ai-playbook 配下がハッシュ対象に含まれている"
else
  pass
fi

# ── 規範経由の非 .ai-playbook 出力も記録対象に入る ────────────────────────────
#
# 以前は sorted_rels（DCB 自身のテンプレート）しか記録しておらず、
# install_playbook_rules が配置する second-opinion-review.sh / review-gate.yml /
# intake スキル等が記録に無かった。この票の動機だった「review-gate.yml が旧版」
# 「second-opinion-review.sh に上流のバグ修正が未反映」は、まさにこの一覧が
# 挙げるファイル群で、記録に無いため doctor.sh が診断できなかった
# （実測: PR #324 レビュー指摘）。

it "記録は規範経由で配置される非 .ai-playbook 出力のハッシュも持つ"
pb_out="$(new_workdir)/p"
run_bootstrap "$pb_out" --with-claude --with-copilot-review --playbook-from "$PLAYBOOK_SRC" >/dev/null 2>&1
pb_origin="$pb_out$ORIGIN_REL"
missing=""
for rel in \
  scripts/second-opinion-review.sh \
  scripts/review-usable.sh \
  scripts/check-review-usable.sh \
  .github/workflows/copilot-review.yml \
  .github/workflows/review-gate.yml \
  .claude/skills/intake/SKILL.md \
  .claude/skills/land/SKILL.md \
  .claude/agents/explorer.md \
  .claude/agents/implementer.md \
  .github/project-ai-rules.md \
  CLAUDE.md \
  .github/copilot-instructions.md; do
  grep -qF -- "hash:$rel=" "$pb_origin" || missing="$missing $rel"
done
if [[ -z "$missing" ]]; then
  pass
else
  fail "記録に無い規範経由の出力:$missing"
fi

it "上記の記録は実ハッシュと一致する（second-opinion-review.sh を例に）"
recorded_pb="$(sed -n 's|^hash:scripts/second-opinion-review\.sh=||p' "$pb_origin")"
actual_pb="$(dcb_file_sha256_for_test "$pb_out/scripts/second-opinion-review.sh")"
assert_eq "$recorded_pb" "$actual_pb" "second-opinion-review.sh のハッシュ"

it "--dry-run の計画に .devcontainer/ORIGIN が含まれる（生成物一覧との整合）"
dry_out="$(new_workdir)/p"
plan="$(run_bootstrap "$dry_out" --dry-run 2>/dev/null)"
assert_contains "$plan" "plan: $dry_out/.devcontainer/ORIGIN" "dry-run 出力"

# ── 決定性 ────────────────────────────────────────────────────────────────────

it "同じ版・同じフラグで生成し直すと記録が一致する（フラグの指定順が違っても）"
out1="$(new_workdir)/p"
out2="$(new_workdir)/p"
run_bootstrap "$out1" --with-claude --with-aws >/dev/null 2>&1
run_bootstrap "$out2" --with-aws --with-claude >/dev/null 2>&1
if diff -q "$out1$ORIGIN_REL" "$out2$ORIGIN_REL" >/dev/null 2>&1; then
  pass
else
  fail "記録が一致しない:
$(diff "$out1$ORIGIN_REL" "$out2$ORIGIN_REL")"
fi

# ── 対照群: 異なるフラグでは記録が変わる ──────────────────────────────────────

it "異なるフラグで生成すると記録のフラグ欄が異なる（対照群）"
out3="$(new_workdir)/p"
run_bootstrap "$out3" --with-gcp >/dev/null 2>&1
flags_aws="$(sed -n 's/^flags=//p' "$out1$ORIGIN_REL")"
flags_gcp="$(sed -n 's/^flags=//p' "$out3$ORIGIN_REL")"
if [[ "$flags_aws" != "$flags_gcp" ]]; then pass; else fail "flags= が変わっていない: $flags_aws"; fi

# ── 衝突ポリシー（既存の生成物と同じ --force ルールに従う） ──────────────────

it "--force を付けない再実行では既存の記録を温存する（他の生成物と同じ --force ルール）"
out4="$(new_workdir)/p"
run_bootstrap "$out4" --with-aws >/dev/null 2>&1
# 記録済みの内容を明示的な印へ置き換えて温存を確認する（上書きされれば印が消える）。
# sed -i は GNU/BSD で挙動が割れるため使わない。テンポラリへ書いて mv で差し替える。
printf 'version=v0.0.1-mutated\nflags=aws\n' > "$out4$ORIGIN_REL.new"
mv "$out4$ORIGIN_REL.new" "$out4$ORIGIN_REL"
run_bootstrap "$out4" --with-aws >/dev/null 2>&1
assert_contains "$(cat "$out4$ORIGIN_REL")" "v0.0.1-mutated" "温存された記録"

it "--force を付けた再実行では記録を書き直す"
run_bootstrap "$out4" --with-aws --force >/dev/null 2>&1
if grep -q "v0.0.1-mutated" "$out4$ORIGIN_REL"; then
  fail "--force でも記録が書き直されていない"
else
  pass
fi

# ── 既知の限界: 装備を追記する再実行（--force なし）は記録に反映されない ──────
#
# ORIGIN 自体も他の生成物と同じ --force ルールに従うため、既存の記録がある状態で
# 新しい --with-* を追加しても（--force を付けなければ）記録は温存されたままで、
# 新しく増えたファイルのハッシュは記録に追加されない。誤って「変化した」と
# 報告することはない（記録に無いものは比較のしようがない）代わりに、新しく
# 増えたファイルは doctor.sh の診断対象にも入らない。README に明記する限界。

it "既知の限界: --force なしで装備を追記しても新規ファイルは記録に載らない"
out5="$(new_workdir)/p"
run_bootstrap "$out5" >/dev/null 2>&1
run_bootstrap "$out5" --with-aws >/dev/null 2>&1
if grep -q '^hash:scripts/acceptance-remote\.sh=' "$out5$ORIGIN_REL"; then
  fail "追記した装備の生成物が記録に載ってしまった（挙動が変わったなら README の記述も更新すること）"
else
  pass
fi

it "既知の限界: 上記の状態でも doctor.sh は当該ファイルを「変化した」と誤検知しない"
output="$(bash "$DOCTOR" --target-dir "$out5" 2>&1)"
if printf '%s' "$output" | grep -q 'changed since generation.*acceptance-remote'; then
  fail "記録に無いファイルを誤って変化したと報告した"
else
  pass
fi

# ── 記録の無い既存生成先への遡及を禁じる ──────────────────────────────────────
#
# write_file / apply_file_with_policy が既存ファイルを skip しても、write_origin_record
# はその現物をハッシュして「今回の実行が生成した」記録として書いてはならない。
# 記録だけを消し、生成物を 1 つ改造した状態で --force なしで再実行すると、
# 以前の実装は改造後の内容を「生成時から変化なし」として記録してしまい、
# README の「記録の無い生成先への遡及はできない」という契約を破っていた
# （実測: PR #324 レビュー指摘）。

it "記録が無い状態で再実行しても、既存ファイルが 1 つでも skip されれば記録を作らない（遡及の禁止）"
retro_out="$(new_workdir)/p"
run_bootstrap "$retro_out" >/dev/null 2>&1
rm -f "$retro_out$ORIGIN_REL"
printf '\n# tampered\n' >> "$retro_out/scripts/on-attach.sh"
run_bootstrap "$retro_out" >/dev/null 2>&1
assert_file_absent "$retro_out$ORIGIN_REL"

it "対照群: 改造が無くても、1 つでも skip があれば同様に記録を作らない（内容の同一性までは見ない設計）"
# 上のケースとの違いは「改造の有無」だけ。改造していなければ skip されたファイルの
# 内容は生成直後と変わらないが、現行の実装は「skip されたファイルの内容が生成直後と
# 同一か」までは見ておらず、skip が 1 件でもあれば一律に記録を作らない（コメントに
# 書いた「対象のどれか 1 つでも skip されていたら作らない」という設計どおり）。
# 過大な約束をしない側（同一性の判定を持たない）を選んだことを、ここで対照として
# 固定する。
noop_out="$(new_workdir)/p"
run_bootstrap "$noop_out" >/dev/null 2>&1
rm -f "$noop_out$ORIGIN_REL"
run_bootstrap "$noop_out" >/dev/null 2>&1
assert_file_absent "$noop_out$ORIGIN_REL"

it "遡及禁止のあとも doctor.sh は改造を「変化なし」と誤診断しない（記録が無いので診断できないと言う）"
output_retro="$(bash "$DOCTOR" --target-dir "$retro_out" 2>&1)"
if printf '%s' "$output_retro" | grep -q 'unchanged since generation'; then
  fail "記録が無いのに unchanged と報告した:
$output_retro"
elif printf '%s' "$output_retro" | grep -q 'origin record missing'; then
  pass
else
  fail "想定外の出力:
$output_retro"
fi

# ── bootstrap.sh と doctor.sh の DCB_VERSION が一致する ──────────────────────
#
# 2 ファイルは互いを参照できない（doctor.sh は curl で単体取得されうる）ため
# DCB_VERSION を複製で持つ。ずれると doctor.sh の「上流が更新されている」判定が
# 自分自身の版を誤って報告する。

it "bootstrap.sh と doctor.sh の DCB_VERSION が一致する"
bv="$(dcb_version_of "$BOOTSTRAP")"
dv="$(dcb_version_of "$DOCTOR")"
if [[ -n "$bv" && "$bv" == "$dv" ]]; then
  pass
else
  fail "DCB_VERSION が不一致（bootstrap.sh=$bv doctor.sh=$dv）"
fi

exit_with_result
