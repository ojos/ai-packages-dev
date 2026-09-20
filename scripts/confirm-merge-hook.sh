#!/usr/bin/env bash
# confirm-merge-hook.sh — マージ実行の前に確認を挟む PreToolUse フック。
#
# 規範（role-contracts/closer.md）は「既定の merge 方針は手動承認とする」と定めるが、
# 呼びかけでは破れる。ある利用プロジェクトでは、対話中の許可承認によりマージコマンドが
# 技術的に実行可能になった結果、承認を経ないまま PR 2 本がマージされた。実行できることと
# 実行してよいことが混同された形で、shared-ai-rules.md 12 章が「機構で保証する」を
# 求める対象そのものにあたる。
#
# 保証するのは「黙ってマージしない」ことであって「マージさせない」ことではない。判定は
# deny ではなく ask を返し、利用者が承認すればマージは実行される。指示に従うマージまで
# 塞ぐと「PR を作り、指示を待ち、指示されたらマージする」という本来の運用が成り立たない。
#
# ── なぜ settings.json の permissions.ask で足りないか ────────────────────────
#
# permissions の allow / ask / deny は、コマンド名と引数文字列の前方一致で判定する
# （実測。下記の 2 例はいずれも harmless な echo で確認した）。そのため次を表現できない。
#
#   - 同じ操作の別経路: gh pr merge を対象にした規則は gh api --method PUT .../merge や
#     gh api graphql の mergePullRequest に一致しない。gh api ごと対象にすると、状態を
#     変えない GET まで確認を求める。
#   - 引数の位置に依らない判定: --method PUT が引数の途中や末尾へ来る綴りは、前方一致
#     では捕捉できない（実測: deny 規則 Bash(echo --method PUT:*) は
#     `echo --method PUT repos/o/r/pulls/1/merge` を止めるが、
#     `echo repos/o/r/pulls/1/merge --method PUT` は素通りする）。
#
# 迂回できる機構は守られている外観だけを作る（12 章）。フックは文字列全体を検査できる
# ため、上の 2 つを 1 か所で扱える。
#
# なお「連結（cd ... && gh pr merge）が前方一致を抜ける」は理由として採らない。実測では
# deny 規則 Bash(echo alpha:*) が `cd /tmp && echo alpha beta` を止めており、&& で連結した
# 各コマンドが個別に判定されていた。実行環境の版によって変わり得る挙動であり、この
# フックは連結も捕捉するが、permissions で足りない理由としては上の 2 点だけを挙げる。
#
# ── 検査対象 ──────────────────────────────────────────────────────────────────
#
#   1. gh pr merge          — コマンド位置にあるもの
#   2. pulls/<n>/merge      — かつ PUT を指定しているもの（REST 経由の merge 実行）
#   3. mergePullRequest     — かつ gh api graphql から呼ばれているもの
#
# いずれも「文字列に含まれるか」ではなく「実行しようとしているか」で判定する。単純な
# 部分一致にすると `grep -rn 'mergePullRequest' .` や `git log -S 'gh pr merge'`、GET での
# `pulls/1/merge`（マージ済みか調べるだけ）まで確認を要求する。確認が頻発すれば内容を
# 読まずに承認する習慣ができ、機構は形だけになる。
#
# ── コマンド位置の判定: 列挙 + 解析の二重化 ──────────────────────────────────
#
# 「コマンド位置か」を 2 つの独立した経路で判定し、どちらかが一致すれば ask にする。
#
#   (a) 列挙（正規表現の前方一致 cmd_pos）: 行頭、または ; && || | ( の直後、
#       シェルの制御語（if / elif / while / until / then / do）の直後、否定 ! の
#       直後を、コマンド位置とみなす前置きとして列挙する。区切り文字の直後という
#       条件だけでは、`if gh pr merge 1; then :; fi` のように制御語を 1 つ前置く
#       だけで素通りしていた（実測）。列挙である以上、ここに挙げていない制御語や
#       書き方は引き続き漏れ得る。
#   (b) 解析（command_position_has、下で定義）: クォートを認識しながら文字単位で
#       区切り文字を走査し、単純コマンドごとの語のリストを組み立てて、期待する
#       語列と完全一致するかを見る。列挙にない書き方（多重の制御語の入れ子など）
#       にも届くが、bash の文法を全部実装したものではない（範囲は関数側のコメント
#       に明記する）。
#
# (a) と (b) を両方残すのは、役割が違うため。(a) は実測した迂回を確実に塞ぐ下限の
# 保証であり、(b) が仮に取りこぼしても揺らがない。(b) は未知の書き方に届く代わりに
# 部分実装であり、取りこぼしも誤検知も起こしうる。**「迂回できない」とは書かない。**
# 塞ぐのは実測で確認した形と、解析が届く範囲だけである。先行する環境変数代入は
# どちらの経路でも読み飛ばす。前方一致にしないのは cd との連結を捕捉するためで、
# 逆に引用符の内側は両方の経路で通る。
#
# ── fail-open にしない ───────────────────────────────────────────────────────
#
# jq でコマンドを取り出せなかった場合は、ペイロード全体を検査対象にする。「取れなければ
# 通す」にすると、jq が無い環境・壊れた JSON・将来のペイロード変更のいずれでも検査を黙って
# 飛ばして通す。検知層が黙って無効化されるのは最悪の壊れ方で、このフックが防ごうとして
# いる「気づかないまま実行できる」状態そのものを再現する。出力側も同じ理由で jq に
# 依存させない（printf のフォールバックを持つ）。
#
# ── 既知の限界（意図的に塞がない）────────────────────────────────────────────
#
# これは「うっかり実行」に確認を挟む guardrail であって、意図的な迂回を防ぐ
# security boundary ではない。文字列照合である以上、書き方を変えれば抜けられる。
#
#   gh -R owner/repo pr merge 1      gh とサブコマンドの間にオプションが挟まる形
#   /usr/bin/gh pr merge 1           絶対パス・相対パスでの起動
#   env gh pr merge 1                env / command などのプレフィックス
#   bash -c "gh pr merge 1"          引用符の内側（引用符の内側を通すことの裏返し）
#   gh api .../pulls/$N/merge        URL に変数展開を含む形
#   gh api graphql -F query=@q.gql   クエリを外部ファイルから読む形
#
# なお -XPUT（連結形）・--method=PUT（= 連結）・--method put（小文字）は、上の一覧とは
# 違って意図的な迂回ではなく curl 風のごく普通の綴りである（実測: いずれも gh が受理する）。
# 「うっかり実行」の側にあたるため、下の判定はこれらも拾う。
#
# ペイロードが空（stdin が空）の場合は確認を求める（ask）。マージコマンドを検知した
# のではなく、検査そのものが成立しなかったことを理由文で伝える。将来ペイロードの
# 渡し方が変わって stdin へ何も来なくなったときにここで気づけるようにするための措置
# であって、配線が生きていることそのものを保証するものではない。配線が生きている
# ことは、フックへ実際にペイロードを流して確かめる以外に保証できない。
#
# 塞ぐたびに新しい書き方が見つかるため、完全性は達成できない。完全であるかのように
# 記録すると、実態より強い保証があると誤認させる（12 章）。
#
# main への直接 push は扱わない。ブランチ保護がサーバ側で拒否しており、そちらのほうが
# 確実なため。ブランチ名に main を含む feature ブランチへの push を誤って止める副作用も
# 避けられる。
#
# 副作用: マージコマンドに見える文字列を行頭に含むコミットメッセージやテストは、そのまま
# では実行できず確認を求められる。ファイル経由（git commit -F、テストスクリプト）で
# 回避できる。
#
# 終了コード: 常に 0。判定は標準出力の JSON（permissionDecision）で伝える。
set -uo pipefail

# シェルの語をクォート認識で切り出し、区切り文字（; & && | || ( ) と改行）で
# 「単純コマンドの語のリスト」へ分解しながら、各単純コマンドが、先頭の環境変数
# 代入（FOO=bar）とシェルの制御語（if / elif / while / until / then / do / !）の
# 繰り返しを読み飛ばした直後に、指定した語列（例: gh pr merge）と完全一致するかを
# その場で確かめる。正規表現の前方一致（cmd_pos）とは別経路で同じ問いに答える
# ための第二の判定で、上のヘッダ「コマンド位置の判定」に対応する。
#
# 引数: 検査対象テキスト、続けて期待する語（可変長。例: gh pr merge）。
# 戻り値: 0 = 一致する単純コマンドがある、1 = 無い。
#
# 解析する範囲: 上記の区切り文字と改行、単一引用符・二重引用符の中身（二重引用符
# 内のバックスラッシュエスケープを含む）、引用符の外のバックスラッシュエスケープ。
#
# 解析しない範囲（意図的に見ない。列挙による cmd_pos 側が、ここでの取りこぼしに
# 対する下限の保証になる。bash の文法を完全に実装すると雛形として重くなりすぎる
# ため、範囲を絞っている）:
#   - 変数展開・コマンド置換・算術展開（$(...) `...` $((...))）の中身。展開の
#     結果によってコマンドが変わる形までは追わない
#   - here-document（<<, <<-, <<<）の本体。区切り文字と同じ規則で割ってしまう
#     （本体に ; や改行があれば、そこで単純コマンドが終わったと誤認する）
#   - サブシェルの深さ。( と ) は対応を数えず常に境界として扱う
#   - for / case / function などの構文そのもの（予約語としては扱わない）。ただし
#     for ... ; do や case ... ) は、; や ) が境界になる副作用で結果的に多くの形を
#     拾える
#
# ここが取りこぼしても cmd_pos（列挙）側が下限を保証し、逆にここが列挙にない形を
# 拾っても「同一行の別コマンド」のような対照群を壊さないことをテストで確かめている。
command_position_has() {
  local text="$1"
  shift
  local -a expect=("$@")
  local -a words=()
  local word="" have_word=0
  local in_squote=0 in_dquote=0
  local i n c found=0

  n=${#text}

  check_and_reset() {
    if [[ $have_word -eq 1 ]]; then
      words+=("$word")
      word=""
      have_word=0
    fi
    if [[ ${#words[@]} -gt 0 ]]; then
      local idx=0 w0
      while [[ $idx -lt ${#words[@]} ]]; do
        w0="${words[$idx]}"
        if [[ "$w0" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
          idx=$((idx + 1))
          continue
        fi
        case "$w0" in
          if | elif | while | until | then | do | '!')
            idx=$((idx + 1))
            continue
            ;;
        esac
        break
      done
      local j=0 ok=1
      while [[ $j -lt ${#expect[@]} ]]; do
        if [[ "${words[$((idx + j))]:-}" != "${expect[$j]}" ]]; then
          ok=0
          break
        fi
        j=$((j + 1))
      done
      [[ $ok -eq 1 ]] && found=1
    fi
    words=()
  }

  for ((i = 0; i < n; i++)); do
    c="${text:i:1}"

    if [[ $in_squote -eq 1 ]]; then
      if [[ "$c" == "'" ]]; then
        in_squote=0
      else
        word+="$c"
        have_word=1
      fi
      continue
    fi
    if [[ $in_dquote -eq 1 ]]; then
      if [[ "$c" == '"' ]]; then
        in_dquote=0
      elif [[ "$c" == $'\\' ]]; then
        i=$((i + 1))
        if [[ $i -lt $n ]]; then
          word+="${text:i:1}"
          have_word=1
        fi
      else
        word+="$c"
        have_word=1
      fi
      continue
    fi

    case "$c" in
      "'") in_squote=1 ;;
      '"') in_dquote=1 ;;
      $'\\')
        i=$((i + 1))
        if [[ $i -lt $n ]]; then
          word+="${text:i:1}"
          have_word=1
        fi
        ;;
      ' ' | $'\t')
        if [[ $have_word -eq 1 ]]; then
          words+=("$word")
          word=""
          have_word=0
        fi
        ;;
      $'\n' | ';' | '&' | '|' | '(' | ')')
        check_and_reset
        # && / || の 2 文字目は読み飛ばす（境界としては 1 回でよい）。
        if { [[ "$c" == '&' ]] || [[ "$c" == '|' ]]; } \
          && [[ "${text:$((i + 1)):1}" == "$c" ]]; then
          i=$((i + 1))
        fi
        ;;
      *)
        word+="$c"
        have_word=1
        ;;
    esac
  done
  check_and_reset

  [[ $found -eq 1 ]]
}

payload="$(cat)"

reason=""

if [[ -z "$payload" ]]; then
  # ペイロードが空＝配線不全の疑い。matcher で絞られた Bash ツール実行に対して
  # PreToolUse から何も渡っていないということは、フックが実行はされていても実質
  # 機能していない状態になり得る。jq 不在時に「取れなければ通す」を採らなかったのと
  # 同じ理由（検知層が黙って無効化されるのは最悪の壊れ方）で、ここも fail-open に
  # しない。ただしマージを検知したわけではないので、理由文はマージ云々ではなく
  # 「検査が成立しなかったこと」を伝える内容にする。
  reason='PreToolUse フックへ届いたペイロードが空でした。マージを検知したのではなく、検査そのものが成立していません。.claude/settings.json の PreToolUse 配線を確認してください。'
else
  # 検査対象の決定。Bash ツールのコマンド文字列を取り出せればそれを、取り出せなければ
  # ペイロード全体を対象にする（fail-open にしない）。全体を対象にすると確認が増える
  # 側へ振れるが、検査を飛ばす側へ振れるより安全である。
  target=""
  if command -v jq >/dev/null 2>&1; then
    target="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null)"
  fi
  extracted=yes
  if [[ -z "$target" ]]; then
    extracted=no
    target="$payload"
  fi

  # バックスラッシュ行継続（\ + 改行）だけを空白へ正規化する。判定にのみ使い、
  # payload・target 自体や理由文は書き換えない。長い REST 呼び出しを \ で複数行に
  # 分けるのは普通の書き方で、-XPUT / --method=PUT と同じ「うっかり実行」側にあたる。
  # 分けて書くと pulls/<n>/merge と PUT が別行になり、REST 判定の同一節条件が外れて
  # 検知漏れになる（実測）。
  #
  # 改行を一律には潰さない。無関係な 2 行（例: echo の次行にたまたま別の gh api 呼び
  # 出しが続くだけの形）まで 1 行へ結合すると、同一節条件が意味を失い誤検知する。
  # 落とすのは直前にバックスラッシュがある改行だけにする。
  #
  # CRLF を先に処理する。LF だけを落とすと \ + CR が残り、CR が語末境界として働いて
  # 判定が外れる。CRLF がこのフックへ届く経路は実測できていないが、置換 1 行で
  # 恒久的に問いを消せるため入れておく。
  norm_target="${target//$'\\\r\n'/ }"
  norm_target="${norm_target//$'\\\n'/ }"

  # コマンド位置の前置き（列挙）。行頭、または ; && || | ( の直後で、先行する環境
  # 変数代入（FOO=bar gh ...）を読み飛ばす。grep は行単位で見るため ^ が各行の
  # 先頭に効く。
  #
  # それらの直後に加え、シェルの制御語（if / elif / while / until / then / do）の
  # 直後と、否定の ! の直後も同じくコマンド位置として扱う。制御語は複数連なり
  # 得る（if false; then while ...; do のような形）ため * で繰り返しを許す。
  # 列挙である以上、ここに挙げていない書き方は引き続き漏れ得る。この取りこぼしは
  # command_position_has（解析）が別経路で拾うことがある。
  #
  # 取り出しに失敗したときはこの前置きを外す。ペイロード全体はシェルの行ではなく JSON
  # であり、コマンドは引用符の内側に現れる。位置を問う条件をそのまま当てると必ず外れ、
  # 「全体を検査対象にする」が実質 fail-open になる（実測: 壊れた JSON
  # {"tool_input": {"command": "gh pr merge 1" が素通りした）。取り出せていない以上
  # 位置は判定できないため、位置を問わない照合へ落として確認を増やす側へ振る。
  # command_position_has 側も同じ理由で、取り出せたとき（extracted == yes）だけ使う
  # （JSON テキストをシェルの語として解析しても意味を持たない）。
  cmd_pos='(^|[;&|(])[[:space:]]*((if|elif|while|until|then|do)[[:space:]]+)*!?[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*'
  if [[ "$extracted" == "no" ]]; then
    cmd_pos=''
  fi

  # 語末の境界。空白か行末だけにすると、JSON の引用符（"gh pr merge"）に隣接した形を
  # 取りこぼす。逆に境界を置かないと gh pr mergequeue のような別サブコマンドまで拾う。
  word_end='([^A-Za-z0-9_-]|$)'

  # パイプは使わずヒアストリングで渡す。grep -q は一致した時点で終了するため、上流を
  # パイプにすると SIGPIPE で pipefail が発火し、一致したのに条件が偽になる経路ができる。
  #
  # 列挙（grep）と解析（command_position_has）の OR。どちらかが一致すれば ask にする。
  if grep -qE "${cmd_pos}gh[[:space:]]+pr[[:space:]]+merge${word_end}" <<<"$norm_target" \
    || { [[ "$extracted" == "yes" ]] && command_position_has "$norm_target" gh pr merge; }; then
    reason='gh pr merge をコマンド位置で実行しようとしています。既定の merge 方針は手動承認です。承認の記録を確認してください。'
  else
    # REST 経由の merge。PUT の指定と merge エンドポイントが同じコマンド節にある
    # ことを条件にする。GET は「マージ済みか」を調べるだけで状態を変えないため
    # 対象にしない。
    #
    # --method PUT（空白区切り）に加え、--method=PUT（= 連結）・-XPUT（-X への直接連結）・
    # --method put（小文字）も拾う。value 側の大小混在は [Pp][Uu][Tt] で吸収する
    # （GET 側はそもそもこのパターンに現れないため波及しない）。
    #
    # PUT の直後には word_end を要求する。無いと -XPUTS のような無関係な綴りまで拾う。
    # --method の直後は区切り（= か空白）を要求する。無いと --methodology のような別
    # オプション名の内部にまで一致する。norm_target を見るので、\ 行継続で PUT が
    # 次行にずれていても同一節条件を満たす。
    #
    # 「同じ行」を「同じコマンド節」の代わりに使うと誤検知する（実測）。
    # `echo repos/o/r/pulls/1/merge; gh api --method PUT repos/o/r/issues/1/labels`
    # は無関係な 2 つのコマンドが ; で 1 行に連結されているだけだが、行単位では
    # 両方が同じ行に現れるため PUT と merge エンドポイントの組が誤って一致する。
    # ; & | はコマンドをつなぐ区切りなので、判定の直前にこれらを改行へ立て替えて
    # 「行」ではなく「コマンド節」を単位にする。バックスラッシュ行継続の正規化
    # （\ + 改行 → 空白）は既に済んでいるため、ここでの立て替えが継続の途中を
    # 割ることはない。
    clause_target="${norm_target//[;&|]/$'\n'}"
    merge_endpoint_lines="$(grep -E 'pulls/[0-9]+/merge' <<<"$clause_target")"
    if [[ -n "$merge_endpoint_lines" ]] \
      && grep -qE "(--method(=|[[:space:]]+)|-X[[:space:]]*)[Pp][Uu][Tt]${word_end}" \
        <<<"$merge_endpoint_lines"; then
      reason='PR の merge エンドポイントへ PUT を実行しようとしています（REST 経由の merge）。既定の merge 方針は手動承認です。承認の記録を確認してください。'
    elif grep -qF 'mergePullRequest' <<<"$norm_target" \
      && { grep -qE "${cmd_pos}gh[[:space:]]+api[[:space:]]+graphql${word_end}" <<<"$norm_target" \
        || { [[ "$extracted" == "yes" ]] && command_position_has "$norm_target" gh api graphql; }; }; then
      # graphql だけは行をまたぐ判定にする。クエリはヒアドキュメントや複数行の
      # -f query=... で渡されることがあり、同じ行にあることを条件にすると外れる。
      reason='gh api graphql から mergePullRequest を実行しようとしています。既定の merge 方針は手動承認です。承認の記録を確認してください。'
    fi
  fi
fi

if [[ -z "$reason" ]]; then
  exit 0
fi

# 出力も jq に依存させない。理由文には二重引用符とバックスラッシュを含めないため、
# フォールバックの printf でも JSON として妥当な出力になる。
if command -v jq >/dev/null 2>&1; then
  jq -n --arg reason "$reason" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "ask",
      permissionDecisionReason: $reason
    }
  }'
else
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"%s"}}\n' "$reason"
fi
exit 0
