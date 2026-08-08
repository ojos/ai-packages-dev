#!/usr/bin/env bash
# test-gh-token-pat.sh — GH_TOKEN による gh 認証の PAT 固定経路を検証する。
#
# 背景: gh の OAuth App には「ユーザー × アプリ × scope あたり 10 トークン」の上限が
# あり、上限に達した状態でどこかの環境が認証すると GitHub が既存のトークンを 1 本
# 破棄する（理由コード max_for_app）。PAT はこの枠の外にあるため、.env の GH_TOKEN で
# 認証を固定する経路を配布物へ取り込んだ。
#
# ここで守りたい性質は 4 つ。いずれも壊れても静かで、実運用で他環境の認証が消える
# 形でしか表面化しない。
#
#   1. .env.example が GH_TOKEN を「キー名だけ」で配り、なぜ gh だけ例外なのかの
#      理由を残していること。
#   2. on-attach.sh 自身が load-project-env.sh を通ること。rc への注入は「これから
#      開く対話シェル」にしか効かず、bash で実行される on-attach.sh 自身には届かない。
#      読まないと GH_TOKEN が常に空に見え、PAT モードの利用者が未認証と誤認される。
#   3. gh auth status に --active が付くこと。GH_TOKEN と hosts.yml の保存済み認証は
#      共存しうるため、付けないと使っていない側が無効なだけで exit=1 になる。
#   4. 案内が「gh が読む環境変数トークン」の有無で出し分かること。対象は GH_TOKEN
#      だけではない。gh は GH_TOKEN -> GITHUB_TOKEN の順に読み、空文字だけを読み
#      飛ばす。GH_TOKEN しか見ないと、GITHUB_TOKEN が効いている環境で「保存済み
#      認証を使用」と誤報告し、失敗時に 'gh auth login' を案内する。案内どおりに
#      進めると、gh の拒否メッセージに従って値を空にしてログインすることになり、
#      OAuth トークンの上限枠を 1 つ消費する。
#
# 到達性については「断定しない」ことを検査する。gh の出力では「到達できない」と
# 「認証が無効」を区別できず（到達できないときも "The token in GH_TOKEN is invalid."
# と言う）、/dev/tcp による直接接続はプロキシ経由の環境で誤判定するため、配布物は
# どちらとも断定しない側へ寄せている。断定へ戻ったことを検出できる形で検査する。

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-gh-token-pat"

out="$(new_workdir)/p"
run_bootstrap "$out" >/dev/null 2>&1
ENVEX="$out/.env.example"
OA="$out/scripts/on-attach.sh"

# ── .env.example ─────────────────────────────────────────────────────────────

it ".env.example が GH_TOKEN のキーを持つ"
if grep -q '^GH_TOKEN=$' "$ENVEX"; then
  pass
else
  fail "GH_TOKEN= の行が無い、または値が書かれている: $(grep -n 'GH_TOKEN' "$ENVEX" | tr '\n' ' ')"
fi

it ".env.example に値が入っていない（雛形として配る）"
# 機密の取り扱い上、配る雛形は値を持たない。GH_TOKEN を足したことで PAT の実値が
# 紛れ込む経路を作っていないことを、キー全体に対して確認する。
if grep -qE '^[A-Z_]+=.+' "$ENVEX"; then
  fail "値が書かれている: $(grep -E '^[A-Z_]+=.+' "$ENVEX" | tr '\n' ' ')"
else
  pass
fi

it ".env.example が GH_TOKEN を置く理由（OAuth App の上限）を残している"
# 理由が消えると「認証はコンテナ内で行う」という原則との矛盾だけが残り、
# 次の担当者がこのキーを削除してしまう。
if grep -q 'max_for_app' "$ENVEX"; then pass; else fail "理由コード max_for_app が書かれていない"; fi

it ".env.example が GIT_IDENTITY_* と方針が逆である理由を並べて残している"
# gh は同名、git は別名。逆に見えるのは理由が違うからで、その差が書かれていないと
# 「片方に揃える」方向の変更を誘発する。
if grep -q 'user.useConfigOnly' "$ENVEX"; then pass; else fail "GIT_IDENTITY_* との差の理由が書かれていない"; fi

# ── on-attach.sh の構造 ──────────────────────────────────────────────────────

it "on-attach.sh 自身が load-project-env.sh を source する"
# 実行時の挙動は後段のシナリオで確認する。ここでは「そもそも読む行があるか」を見て、
# 挙動が壊れたときに原因の切り分けを 1 段速くする。
if grep -qE '^\s*\.\s+"\$HELPER"$' "$OA"; then pass; else fail "ローダーを source する行が無い"; fi

it "gh auth status に --active が付く"
if grep -q 'gh auth status --active' "$OA"; then pass; else fail "--active が付いていない"; fi

it "gh auth status を timeout で打ち切る"
if grep -q 'timeout "\$GH_AUTH_TIMEOUT_SECS" gh auth status' "$OA"; then
  pass
else
  fail "timeout による打ち切りが無い"
fi

it "到達性を /dev/tcp で断定しない"
# 直接接続はプロキシ経由の環境で塞がれ、gh が疎通していても不通と誤判定する。
# コメント行は対象外にする。採らなかった理由として /dev/tcp に言及する行が
# スクリプト内にあり、それごと落とすと理由を書けなくなる。
if grep -vE '^[[:space:]]*#' "$OA" | grep -q '/dev/tcp'; then
  fail "/dev/tcp による到達性判定が入っている（プロキシ環境で誤判定する）"
else
  pass
fi

it "/dev/tcp を採らなかった理由がスクリプトに残っている"
# 「検査していない」ではなく「断定できないので断定しない」という判断であることを、
# 次に触る人が読める形で残す。理由が消えると、素朴な到達性判定が戻ってくる。
if grep -q '/dev/tcp' "$OA"; then pass; else fail "採らなかった理由が書かれていない"; fi

it "到達性を断定しないことが利用者向けの文言にも出ている"
if grep -q '認証は判定していません' "$OA"; then pass; else fail "保留の案内が無い"; fi

# ── 実行時の挙動 ─────────────────────────────────────────────────────────────
#
# gh と timeout を差し替えたサンドボックスで on-attach.sh を実行し、案内が
# GH_TOKEN の有無で出し分かることを両方向で確かめる。
#
# setup-git-identity.sh は no-op へ差し替える。実物は global の git config を
# 書き換えるため、ここで走らせると検証対象と無関係な副作用が入る（失敗しても
# on-attach は WARN に留めて 0 で終わるため、判定自体には影響しない）。

sb="$(new_workdir)/sb"
mkdir -p "$sb/scripts" "$sb/bin" "$sb/bin-timeout" "$sb/home"
cp "$OA" "$out/scripts/load-project-env.sh" "$sb/scripts/"
printf '#!/usr/bin/env bash\nexit 0\n' > "$sb/scripts/setup-git-identity.sh"

# 呼ばれた引数を記録し、GH_STUB_EXIT の値で終了する gh。
cat > "$sb/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_STUB_ARGS_FILE"
exit "${GH_STUB_EXIT:-0}"
STUB
chmod +x "$sb/bin/gh"

# 打ち切りを再現する timeout。実際に待つと 1 ケースで 10 秒かかるため、
# コマンドを起動せず 124 だけを返す（timeout(1) が打ち切り時に返す値）。
cat > "$sb/bin-timeout/timeout" <<'STUB'
#!/usr/bin/env bash
exit 124
STUB
chmod +x "$sb/bin-timeout/timeout"

ARGS_FILE="$sb/gh-args.txt"

# on-attach.sh を隔離実行し、"<rc>\n<stdout+stderr>" を返す。
# $1 = gh の終了コード, $2 = .env の内容（空文字なら .env を置かない）,
# $3 = 追加で先頭へ差し込む PATH（空可）
run_on_attach() {
  local gh_exit="$1" envbody="$2" extra_path="${3:-}" combined rc=0
  rm -f "$sb/.env" "$ARGS_FILE"
  : > "$ARGS_FILE"
  [[ -n "$envbody" ]] && printf '%s\n' "$envbody" > "$sb/.env"
  rm -rf "${sb:?}/home"; mkdir -p "$sb/home"
  combined="$(
    HOME="$sb/home" \
    PATH="${extra_path:+$extra_path:}$sb/bin:$PATH" \
    GH_STUB_EXIT="$gh_exit" \
    GH_STUB_ARGS_FILE="$ARGS_FILE" \
    bash "$sb/scripts/on-attach.sh" 2>&1
  )" || rc=$?
  printf '%s\n%s' "$rc" "$combined"
}

# ── GH_TOKEN が空（従来経路） ────────────────────────────────────────────────

res="$(run_on_attach 0 '')"
it "GH_TOKEN が空で認証が有効なら、保存済み認証を使っている旨を報告する"
assert_contains "$res" '保存済み認証を使用' "on-attach 出力"

res="$(run_on_attach 1 '')"
it "GH_TOKEN が空で認証を確認できないとき、従来どおり 'gh auth login' を案内する"
assert_contains "$res" "'gh auth login' を実行してください" "on-attach 出力"

it "GH_TOKEN が空でも到達性は断定しない"
assert_contains "$res" '認証は判定していません' "on-attach 出力"

# ── GH_TOKEN が非空（PAT モード） ────────────────────────────────────────────
#
# .env にだけ書く。環境変数としては渡さない。ここで PAT モードの分岐へ入ること
# 自体が、on-attach.sh が load-project-env.sh を通っている証拠になる。

res="$(run_on_attach 0 'GH_TOKEN=dummy-pat-value')"
it ".env の GH_TOKEN を on-attach.sh 自身が読む（PAT モードとして報告する）"
assert_contains "$res" 'GH_TOKEN の値を使用' "on-attach 出力"

res="$(run_on_attach 1 'GH_TOKEN=dummy-pat-value')"
it "PAT モードで認証を確認できないとき、'gh auth login' を実行しないよう案内する"
assert_contains "$res" "'gh auth login' は実行しないでください" "on-attach 出力"

it "PAT モードでは 'gh auth login' を実行させる案内を出さない"
# ここが両方向の出し分けの要。gh は値が設定されているあいだログインを拒否するため
# 案内が空振りするうえ（gh 2.96.0 で実測）、拒否メッセージ "first clear the value
# from the environment" に従って値を空にしてログインすると上限枠を 1 つ消費し、
# 上限に達していれば他環境のトークンが 1 本失効する。
case "$res" in
  *"を実行してください"*) fail "PAT モードで login を促す案内が出ている: $(printf '%s' "$res" | grep -F '実行してください' | head -1)" ;;
  *) pass ;;
esac

it "PAT モードでも到達性は断定しない"
assert_contains "$res" '認証は判定していません' "on-attach 出力"

it "認証を確認できなくても on-attach は 0 で終わる"
# 認証の確認は接続時の案内であって、接続そのものを止める理由にはならない。
assert_eq "${res%%$'\n'*}" "0" "on-attach の終了コード"

# ── GH_TOKEN が「空の値として .env にある」場合 ──────────────────────────────
#
# .env.example を複製した利用者の既定状態がこれで、PAT を使わない大多数が通る。
# ローダーは空文字も後勝ちで export するため、GH_TOKEN は「未設定」ではなく
# 「空文字で設定済み」になる。ここで PAT モードへ落ちると、保存済み認証で動いて
# いる利用者が毎回「login するな」と言われ、案内が逆になる。
#
# gh 自身は空文字の GH_TOKEN を資格情報として扱わず hosts.yml へフォールバック
# する（gh 2.96.0 で実測。`GH_TOKEN= gh auth token` は保存済みの gho_ を返し、
# `GH_TOKEN= gh api user` も成功する）。判定を [[ -n ]] にしているのは、この
# gh 側の境界に合わせるため。空白 1 文字のような「空でない値」は gh が資格情報
# として解釈するので、こちらも PAT モードとして扱うのが正しい。

res="$(run_on_attach 0 'GH_TOKEN=')"
it ".env に GH_TOKEN が空で書かれていても PAT モードへ落ちない"
assert_contains "$res" '保存済み認証を使用' "on-attach 出力"

res="$(run_on_attach 1 'GH_TOKEN=')"
it ".env の GH_TOKEN が空なら、認証を確認できないとき 'gh auth login' を案内する"
assert_contains "$res" "'gh auth login' を実行してください" "on-attach 出力"

# ── GITHUB_TOKEN も同じ扱いにする ────────────────────────────────────────────
#
# gh は GH_TOKEN -> GITHUB_TOKEN の順に環境変数を読み、空文字だけを読み飛ばす
# （gh 2.96.0 で実測。`GITHUB_TOKEN=" " gh api user` は Bad credentials、
# `GITHUB_TOKEN=" " GH_TOKEN="" gh api user` も Bad credentials、
# `GITHUB_TOKEN="" gh api user` は保存済み認証で成功）。
#
# GH_TOKEN だけを見ると、GITHUB_TOKEN が効いている環境で「保存済み認証を使用」と
# 誤って報告し、失敗時には 'gh auth login' を案内する。案内どおりに進めると、
# 拒否メッセージに従って値を空にしてログインすることになり、上限枠を 1 つ消費する。
# 本票が塞ごうとしている事故そのものなので、GH_TOKEN と同じ扱いにする。

res="$(run_on_attach 0 'GITHUB_TOKEN=dummy-token-value')"
it "GITHUB_TOKEN が効いているとき「保存済み認証」とは報告しない"
case "$res" in
  *'保存済み認証を使用'*) fail "GITHUB_TOKEN が使われているのに保存済み認証と報告している" ;;
  *) pass ;;
esac

it "GITHUB_TOKEN が効いていることを名前を挙げて報告する"
assert_contains "$res" 'GITHUB_TOKEN の値を使用' "on-attach 出力"

it "GITHUB_TOKEN が優先されている旨を WARN で知らせる"
assert_contains "$res" '恒久的に設定しないでください' "on-attach 出力"

res="$(run_on_attach 1 'GITHUB_TOKEN=dummy-token-value')"
it "GITHUB_TOKEN が効いているときも 'gh auth login' を案内しない"
case "$res" in
  *"を実行してください"*) fail "GITHUB_TOKEN 使用時に login を促す案内が出ている: $(printf '%s' "$res" | grep -F '実行してください' | head -1)" ;;
  *) pass ;;
esac

res="$(run_on_attach 0 'GH_TOKEN=
GITHUB_TOKEN=dummy-token-value')"
it "GH_TOKEN が空で GITHUB_TOKEN に値があるとき、GITHUB_TOKEN 側として扱う"
# 「GH_TOKEN を空にすれば保存済み認証へ戻る」は GITHUB_TOKEN があると成立しない。
# 空の GH_TOKEN は GITHUB_TOKEN に対する盾にならない。
assert_contains "$res" 'GITHUB_TOKEN の値を使用' "on-attach 出力"

res="$(run_on_attach 0 'GH_TOKEN=dummy-pat-value
GITHUB_TOKEN=dummy-token-value')"
it "両方に値があるときは gh の優先順に合わせて GH_TOKEN 側として扱う"
assert_contains "$res" 'GH_TOKEN の値を使用' "on-attach 出力"

# ── --active と打ち切り ──────────────────────────────────────────────────────

it "gh へ渡す引数が 'auth status --active' である"
assert_contains "$(cat "$ARGS_FILE")" 'auth status --active' "gh へ渡した引数"

res="$(run_on_attach 0 'GH_TOKEN=dummy-pat-value' "$sb/bin-timeout")"
it "打ち切り（exit 124）は認証の失敗と分けて報告する"
assert_contains "$res" '秒で完了しませんでした' "on-attach 出力"

it "打ち切りのときも認証は判定していないと言う"
assert_contains "$res" '認証は判定していません' "on-attach 出力"

it "打ち切りのときも PAT モードでは 'gh auth login' を案内しない"
case "$res" in
  *"を実行してください"*) fail "打ち切り時に login を促す案内が出ている" ;;
  *) pass ;;
esac

exit_with_result
