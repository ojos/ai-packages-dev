#!/usr/bin/env bash
# 機密混入検査（scripts/check-no-secrets.sh）を検証する。
#
# 共通規範「機密をコミットしない」の機械化であり、検知層としての性質を検査する。
# 陽性（機密を置いたリポジトリで落ちる）だけでは足りない。陰性（機密の無い
# リポジトリで通る）を併せて見ないと、「常に落ちるだけの検査」と区別が付かず、
# 逆に「常に通るだけの検査」も陽性を書かなければ気づけない。両方向を対にする。
#
# 使い捨てのリポジトリを毎回作るのは、判定対象が git の状態（追跡前 / 追跡済み /
# 管理外）そのものだから。既存のリポジトリを使い回すと、前の検査が残した状態が
# 次の判定へ漏れる。
#
# ネットワークには出ない。
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-check-no-secrets"

# 非 ASCII を含むディレクトリ名。git ls-files が既定（core.quotePath=true）で
# "\NNN..." へエスケープする対象を作るために使う。
NON_ASCII_DIR="日本語ディレクトリ"

GIT_AS="git -c user.name=T -c user.email=t@example.com"

# 生成物の原本。bootstrap は 1 回だけ回し、以降は複製して使う（生成そのものは
# 他のテストが検証しており、ここで何度も回すと所要時間だけが伸びる）。
BASE="$(new_workdir)/base"
run_bootstrap "$BASE" >/dev/null 2>&1

it "check-no-secrets.sh が常に生成され、実行可能である"
if [[ -f "$BASE/scripts/check-no-secrets.sh" ]]; then
  assert_mode "$BASE/scripts/check-no-secrets.sh" "755"
else
  fail "生成されていない: $BASE/scripts/check-no-secrets.sh"
fi

# 生成物の複製を git リポジトリとして用意し、そのパスを返す。
new_repo() {
  local out
  out="$(new_workdir)/p"
  cp -R "$BASE" "$out"
  (
    cd "$out" || exit 1
    git init -q
    git symbolic-ref HEAD refs/heads/main
    git add -A
    $GIT_AS commit -q -m c1
  ) >/dev/null 2>&1
  printf '%s' "$out"
}

# 検査を実行し、CHECK_OUT / CHECK_RC へ結果を入れる。
CHECK_OUT=""
CHECK_RC=0
run_check() {
  local repo="$1"
  shift
  CHECK_OUT="$(cd "$repo" && env "$@" bash scripts/check-no-secrets.sh 2>&1)"
  CHECK_RC=$?
}

# 落ちたこと（SECRETS_FAIL / 非 0）を検査する。
assert_fail() {
  local what="$1" needle="${2-}"
  if [[ "$CHECK_RC" -eq 0 ]]; then
    fail "$what: 落ちるべきところで通過した: $CHECK_OUT"
    return
  fi
  if ! printf '%s' "$CHECK_OUT" | grep -q 'SECRETS_FAIL'; then
    fail "$what: SECRETS_FAIL が出ていない: $CHECK_OUT"
    return
  fi
  if [[ -n "$needle" ]] && ! printf '%s' "$CHECK_OUT" | grep -qF "$needle"; then
    fail "$what: 期待した報告 '$needle' が無い: $CHECK_OUT"
    return
  fi
  pass
}

# 通ったこと（SECRETS_PASS / 0）を検査する。
assert_pass() {
  local what="$1"
  if [[ "$CHECK_RC" -ne 0 ]]; then
    fail "$what: 通るべきところで落ちた: $CHECK_OUT"
  elif ! printf '%s' "$CHECK_OUT" | grep -q 'SECRETS_PASS'; then
    fail "$what: SECRETS_PASS が出ていない: $CHECK_OUT"
  else
    pass
  fi
}

# ── 陰性の基準線 ─────────────────────────────────────────────────────────────

it "機密の無い生成物では SECRETS_PASS（陰性の基準線）"
# これが通らないと、以降の陽性はすべて「常に落ちる検査」でも成立してしまう。
repo="$(new_repo)"
run_check "$repo"
assert_pass "機密なし"

# ── 追跡前の経路（追跡対象へ入る前に落とす） ──────────────────────────────────

it "追跡前: 追跡対象へ入ろうとしている credentials.json を検知する（陽性）"
# 誤ってコミットしてからでは、削除コミットでは漏洩が解消しない。追跡対象へ
# 入る前に落とすのがこの経路の役割。
repo="$(new_repo)"
printf '{}\n' > "$repo/credentials.json"
run_check "$repo"
assert_fail "追跡前" "credentials.json"

it "追跡前: 除外済み（.gitignore）なら検知しない（陰性）"
# .gitignore で除外されていればコミット経路が無い。ここを落とすと、正しく
# 除外している状態が恒常的に赤になる。
repo="$(new_repo)"
printf 'ignored-value\n' > "$repo/.env"   # 生成される .gitignore が .env を除外する
run_check "$repo"
assert_pass "追跡前・除外済み"

it "追跡前: 検知の報告に「追跡対象へ入ろうとしています」が出る"
repo="$(new_repo)"
printf 'x\n' > "$repo/id_rsa"
run_check "$repo"
assert_fail "追跡前の報告" "追跡対象へ入ろうとしています"

# ── 改行を含むパス名（#263） ────────────────────────────────────────────────
#
# 行単位の解析では 1 パスが 2 行へ割れ、追跡前・追跡済みの両経路とも検知できな
# かった（#263 で実測、git 2.53.0）。列挙を NUL 区切りへ変えたことで、両経路とも
# 1 レコードのまま扱えることを確認する。needle は改行をまたがない末尾側
# （credentials.json）で照合する（先頭側は ng() の出力自体が改行を含むため、
# 単純な行単位の grep とは相性が悪い）。
#
# ディレクトリ名の側に改行を仕込む（nl<改行>dir/credentials.json）。SECRET_PATH_RE の
# 判定は `/` 区切りの前で発火する設計であり、改行そのものを区切りとはみなさない。
# 改行がファイル名側にしか無い形（nl<改行>credentials.json、`/` を挟まない）は
# レガシー実装でも SECRET_PATH_RE が一致しない対象で、#263 の主題（行単位の解析が
# 1 パスを 2 行へ割ってしまい、パスの取り出しそのものが失敗すること）を確認する
# には向かない。実測（下の対照）: レガシー実装の `sed -n "s/^add '\(.*\)'\$/\1/p"` は
# この形でも改行の位置に関わらず 1 件も取り出せない（空文字列）。
NEWLINE_SECRET_NAME=$'nl\ndir/credentials.json'

it "追跡前: 改行を含むパス名の credentials.json を検知する（陽性、#263）"
repo="$(new_repo)"
mkdir -p "$repo/${NEWLINE_SECRET_NAME%/*}"
printf '{}\n' > "$repo/$NEWLINE_SECRET_NAME"
run_check "$repo"
if [[ "$CHECK_RC" -eq 0 ]]; then
  fail "落ちるべきところで通過した: $CHECK_OUT"
elif ! printf '%s' "$CHECK_OUT" | grep -q 'SECRETS_FAIL'; then
  fail "SECRETS_FAIL が出ていない: $CHECK_OUT"
elif ! printf '%s' "$CHECK_OUT" | grep -q '追跡対象へ入ろうとしています'; then
  fail "追跡前の報告ラベルが無い: $CHECK_OUT"
elif ! printf '%s' "$CHECK_OUT" | grep -qF 'credentials.json'; then
  fail "パス名が報告に出ていない: $CHECK_OUT"
else
  pass
fi

# ── 追跡済みの経路（CI で落とす層） ───────────────────────────────────────────

it "追跡済み: コミット済みの .env を検知する（陽性）"
# checkout 直後の作業ツリーはクリーンで、追跡前の検査は出力が空になる。この経路が
# 無いと CI は「何も検査していない状態」で合格する。
repo="$(new_repo)"
printf 'K=v\n' > "$repo/.env"
( cd "$repo" && git add -f .env && $GIT_AS commit -q -m add-env ) >/dev/null 2>&1
# 作業ツリーをクリーンにして、追跡前の検査が空になる状況を再現する。
run_check "$repo"
assert_fail "追跡済み" "追跡対象に含まれています"

it "追跡済み: 作業ツリーがクリーンでも検知する（追跡前の検査だけでは素通りする状況）"
repo="$(new_repo)"
printf 'K=v\n' > "$repo/.env"
( cd "$repo" && git add -f .env && $GIT_AS commit -q -m add-env ) >/dev/null 2>&1
dirty="$(cd "$repo" && git status --porcelain)"
if [[ -n "$dirty" ]]; then
  fail "前提が崩れている（作業ツリーがクリーンでない）: $dirty"
else
  run_check "$repo"
  assert_fail "クリーンな作業ツリー" ".env"
fi

it "追跡済み: 改行を含むパス名の credentials.json を検知する（陽性、#263）"
# 追跡前の検査が空になる状況（作業ツリーがクリーン）でも、追跡済み経路が拾うこと
# まで確認する（上の「作業ツリーがクリーンでも検知する」と同じ狙い）。
repo="$(new_repo)"
mkdir -p "$repo/${NEWLINE_SECRET_NAME%/*}"
printf '{}\n' > "$repo/$NEWLINE_SECRET_NAME"
( cd "$repo" && git add -f -- "$NEWLINE_SECRET_NAME" && $GIT_AS commit -q -m add-newline-path ) >/dev/null 2>&1
run_check "$repo"
if [[ "$CHECK_RC" -eq 0 ]]; then
  fail "落ちるべきところで通過した: $CHECK_OUT"
elif ! printf '%s' "$CHECK_OUT" | grep -q 'SECRETS_FAIL'; then
  fail "SECRETS_FAIL が出ていない: $CHECK_OUT"
elif ! printf '%s' "$CHECK_OUT" | grep -q '追跡対象に含まれています'; then
  fail "追跡済みの報告ラベルが無い: $CHECK_OUT"
elif ! printf '%s' "$CHECK_OUT" | grep -qF 'credentials.json'; then
  fail "パス名が報告に出ていない: $CHECK_OUT"
else
  pass
fi

# ── 非 ASCII パス（core.quotePath による検知漏れ） ─────────────────────────────

it "非 ASCII を含むパス配下の追跡済み .env を検知する"
# git ls-files は core.quotePath 既定（true）で非 ASCII を含むパスを "..." で囲み、
# 非 ASCII 部分を \NNN の 8 進エスケープへ置き換える。閉じ引用符が付くことで
# 名前の末尾を見る判定が阻まれ、この 1 件が黙ってすり抜ける。
repo="$(new_repo)"
mkdir -p "$repo/ascii" "$repo/$NON_ASCII_DIR"
printf 'K=v\n' > "$repo/ascii/.env"
printf 'K=v\n' > "$repo/$NON_ASCII_DIR/.env"
( cd "$repo" && git add -f ascii/.env "$NON_ASCII_DIR/.env" && $GIT_AS commit -q -m add-envs ) >/dev/null 2>&1
run_check "$repo"
hits="$(printf '%s' "$CHECK_OUT" | grep -c 'NG 追跡対象に含まれています' || true)"
if [[ "$CHECK_RC" -eq 0 ]]; then
  fail "落ちるべきところで通過した: $CHECK_OUT"
elif [[ "$hits" -ne 2 ]]; then
  fail "追跡済みの .env 2 件のうち $hits 件しか検知していない: $CHECK_OUT"
else
  pass
fi

it "非 ASCII を含むパスの報告がエスケープされていない生パスである（-z 列挙の回帰）"
# 報告が "\346\227\245..." の形で出るなら、判定側も同じエスケープ済み文字列を見て
# いる。上の 2 件検知と対にして、`git ls-files -z` が非 -z（core.quotePath 既定の
# true）へ戻ったことを検知できるようにする（戻ると 1 件が漏れ、もう 1 件は
# .env.example の除外が崩れて誤検知へ化ける）。
if printf '%s' "$CHECK_OUT" | grep -qF "$NON_ASCII_DIR/.env"; then
  if printf '%s' "$CHECK_OUT" | grep -q '\\346'; then
    fail "報告に 8 進エスケープが混じっている: $CHECK_OUT"
  else
    pass
  fi
else
  fail "生パスでの報告が無い: $CHECK_OUT"
fi

it "非 ASCII を含むパス配下の .env.example は検知しない（除外が閉じ引用符に阻まれない）"
# 値のない雛形は共有が前提。エスケープ済みの文字列を見ていると末尾が example" に
# なり、除外判定が成立せず誤検知する。
repo="$(new_repo)"
mkdir -p "$repo/$NON_ASCII_DIR"
printf 'FOO=\n' > "$repo/$NON_ASCII_DIR/.env.example"
( cd "$repo" && git add -f "$NON_ASCII_DIR/.env.example" && $GIT_AS commit -q -m add-example ) >/dev/null 2>&1
run_check "$repo"
assert_pass "非 ASCII 配下の .env.example"

# ── パターンの広さ（改名・退避形と、無関係な名前） ────────────────────────────

it "改名・退避形（credentials.json.bak / terraform.tfstate-backup）を追跡済み経路で検知する"
# 末尾一致に絞ると、この形が片方の経路だけですり抜ける。2 経路は経路が違うだけで
# 守る対象は同じでなければならない。
repo="$(new_repo)"
printf '{}\n' > "$repo/credentials.json.bak"
printf 'x\n' > "$repo/terraform.tfstate-backup"
( cd "$repo" && git add -f credentials.json.bak terraform.tfstate-backup && $GIT_AS commit -q -m add-bak ) >/dev/null 2>&1
run_check "$repo"
hits="$(printf '%s' "$CHECK_OUT" | grep -c 'NG 追跡対象に含まれています' || true)"
if [[ "$CHECK_RC" -eq 0 ]]; then
  fail "落ちるべきところで通過した: $CHECK_OUT"
elif [[ "$hits" -ne 2 ]]; then
  fail "退避形 2 件のうち $hits 件しか検知していない: $CHECK_OUT"
else
  pass
fi

it "改名・退避形を追跡前経路でも検知する（2 経路で同じ広さ）"
repo="$(new_repo)"
printf '{}\n' > "$repo/credentials.json.bak"
printf 'x\n' > "$repo/terraform.tfstate-backup"
run_check "$repo"
hits="$(printf '%s' "$CHECK_OUT" | grep -c 'NG 追跡対象へ入ろうとしています' || true)"
if [[ "$CHECK_RC" -eq 0 ]]; then
  fail "落ちるべきところで通過した: $CHECK_OUT"
elif [[ "$hits" -ne 2 ]]; then
  fail "退避形 2 件のうち $hits 件しか検知していない: $CHECK_OUT"
else
  pass
fi

it "紛らわしいが機密でない名前は検知しない（検査が広すぎないこと）"
# 無制限の後方一致にすると、.environment のような無関係な名前まで .env として
# 拾う。広すぎる検知層は「赤を無視する習慣」を作る。
repo="$(new_repo)"
mkdir -p "$repo/docs"
printf 'x\n' > "$repo/docs/setup.environment.md"
printf 'x\n' > "$repo/docs/monkeys.txt"
printf 'x\n' > "$repo/docs/keys.md"
run_check "$repo"
assert_pass "紛らわしい名前"

# ── パターンの広さ（名前系トークンの接頭辞） ────────────────────────────────────
#
# 先頭固定 (^|/) のままだと dev-credentials.json のような接頭辞付きの名前が
# すり抜ける。名前系トークン（credentials.json / client_secret /
# service[-_]account）の 3 つに限り前方の境界 ([^/]*[-._~])? を許す。

it "接頭辞付きの名前系トークン（dev-credentials.json / prod-service-account.json / my-client_secret.json）を追跡済み経路で検知する"
repo="$(new_repo)"
printf '{}\n' > "$repo/dev-credentials.json"
printf '{}\n' > "$repo/prod-service-account.json"
printf '{}\n' > "$repo/my-client_secret.json"
( cd "$repo" && git add -f dev-credentials.json prod-service-account.json my-client_secret.json && $GIT_AS commit -q -m add-prefixed ) >/dev/null 2>&1
run_check "$repo"
hits="$(printf '%s' "$CHECK_OUT" | grep -c 'NG 追跡対象に含まれています' || true)"
if [[ "$CHECK_RC" -eq 0 ]]; then
  fail "落ちるべきところで通過した: $CHECK_OUT"
elif [[ "$hits" -ne 3 ]]; then
  fail "接頭辞付き 3 件のうち $hits 件しか検知していない: $CHECK_OUT"
else
  pass
fi

it "接頭辞付きの名前系トークンを追跡前経路でも検知する（2 経路で同じ広さ）"
repo="$(new_repo)"
printf '{}\n' > "$repo/dev-credentials.json"
printf '{}\n' > "$repo/prod-service-account.json"
printf '{}\n' > "$repo/my-client_secret.json"
run_check "$repo"
hits="$(printf '%s' "$CHECK_OUT" | grep -c 'NG 追跡対象へ入ろうとしています' || true)"
if [[ "$CHECK_RC" -eq 0 ]]; then
  fail "落ちるべきところで通過した: $CHECK_OUT"
elif [[ "$hits" -ne 3 ]]; then
  fail "接頭辞付き 3 件のうち $hits 件しか検知していない: $CHECK_OUT"
else
  pass
fi

it "foo.env は接頭辞を許した後も検知しない（.env は先頭固定のまま、過検知にしない）"
# .env / .netrc 系は名前系トークンに含めない判断を固定する。含めると
# foo.environment のような無関係な名前まで拾う経路が太くなる。
repo="$(new_repo)"
printf 'x\n' > "$repo/foo.env"
run_check "$repo"
assert_pass "foo.env は接頭辞対象外"

# ── .env.example の機密値 ─────────────────────────────────────────────────────

it ".env.example に機密キーの値が入っていれば落ちる（陽性）"
repo="$(new_repo)"
printf '\nMY_API_TOKEN=%s\n' 'not-a-real-value-000' >> "$repo/.env.example"
run_check "$repo"
assert_fail ".env.example の機密値" "MY_API_TOKEN"

it ".env.example の検知報告に値そのものを出さない"
# 検知層が機密をログへ書き出しては本末転倒（共通規範「ログ・PR 説明に機密を
# 含めない」）。出すのはキー名だけであること。
if printf '%s' "$CHECK_OUT" | grep -qF 'not-a-real-value-000'; then
  fail "値が出力へ漏れている: $CHECK_OUT"
else
  pass
fi

it "修飾付きの機密キー（..._KEY_ID）も部分一致で拾う"
# 語尾一致にすると AWS_SECRET_ACCESS_KEY_ID のような形がすり抜ける。
repo="$(new_repo)"
printf '\nSOME_SECRET_ACCESS_KEY_ID=%s\n' 'x' >> "$repo/.env.example"
run_check "$repo"
assert_fail "修飾付きの機密キー" "SOME_SECRET_ACCESS_KEY_ID"

it "PATH は PAT の語境界要求により機密キーとみなさない"
repo="$(new_repo)"
printf '\nEXTRA_PATH=/usr/local/bin\n' >> "$repo/.env.example"
# キー整合の対象にしないため .env は置かない（.env が無ければ整合はスキップされる）。
run_check "$repo"
assert_pass "PATH は機密キーでない"

it "機密でない設定既定値は雛形で共有できる"
repo="$(new_repo)"
printf '\nREVIEW_ROUNDS=3\n' >> "$repo/.env.example"
run_check "$repo"
assert_pass "非機密の既定値"

# ── .env と .env.example のキー整合 ───────────────────────────────────────────

it "キー整合: .env が .env.example と同じキーなら通す"
repo="$(new_repo)"
cp "$repo/.env.example" "$repo/.env"
run_check "$repo"
assert_pass "キー一致"

it "キー整合: .env にしか無いキーは落とす（雛形が設定項目を伝えていない）"
repo="$(new_repo)"
cp "$repo/.env.example" "$repo/.env"
printf '\nONLY_IN_ENV=\n' >> "$repo/.env"
run_check "$repo"
assert_fail "片側追加（.env 側）" "ONLY_IN_ENV"

it "キー整合: 雛形にしか無いキーは NOTICE に留めて通す"
# 雛形へキーが増えた直後は、各環境の .env が追いつくまで必ずこの状態を通る。
# ここで落とすと配布物の更新のたびに全利用者のゲートが赤くなる。
repo="$(new_repo)"
printf '\nONLY_IN_EXAMPLE=\n' >> "$repo/.env.example"
cp "$repo/.env.example" "$repo/.env"
# .env 側からだけ落とす。
grep -v '^ONLY_IN_EXAMPLE=' "$repo/.env" > "$repo/.env.tmp" && mv "$repo/.env.tmp" "$repo/.env"
run_check "$repo"
if [[ "$CHECK_RC" -ne 0 ]]; then
  fail "NOTICE に留めるべきところで落ちた: $CHECK_OUT"
elif printf '%s' "$CHECK_OUT" | grep -q 'NOTICE.*ONLY_IN_EXAMPLE'; then
  pass
else
  fail "NOTICE が出ていない: $CHECK_OUT"
fi

it "キー整合: .env が無ければスキップして通す（CI）"
repo="$(new_repo)"
run_check "$repo"
if [[ "$CHECK_RC" -ne 0 ]]; then
  fail "通るべきところで落ちた: $CHECK_OUT"
elif printf '%s' "$CHECK_OUT" | grep -q 'キー整合はスキップ'; then
  pass
else
  fail "スキップの明示が無い: $CHECK_OUT"
fi

it "呼び出し元のシェルに値が export されていても判定が変わらない（env -i）"
# 対話シェルには on-attach.sh が .env の読み込みを注入する。呼び出し元の環境を
# そのまま見ると、ファイルに書かれていない値を「雛形に機密が入っている」と誤認する。
repo="$(new_repo)"
run_check "$repo" MY_API_TOKEN=leaked-from-shell GEMINI_API_KEY=leaked-from-shell
assert_pass "呼び出し元の環境からの漏れ込み"

# ── 検査が成立していないことを合格にしない ────────────────────────────────────

it "git 管理外では落ちる（検査が成立していない）"
# 検査が成立していないことと、機密が無いことは別である。
out="$(new_workdir)/p"
cp -R "$BASE" "$out"
run_check "$out"
assert_fail "git 管理外" "git の作業ツリーではありません"

it "追跡ファイルが 1 件も無ければ落ちる"
# 空の出力を「該当なし」と読むと、検査していないのに合格になる。
out="$(new_workdir)/p"
cp -R "$BASE" "$out"
( cd "$out" && git init -q ) >/dev/null 2>&1
run_check "$out"
assert_fail "追跡 0 件" "追跡ファイルが 1 件もありません"

it ".env.example が無ければ落ちる"
repo="$(new_repo)"
( cd "$repo" && git rm -q --cached .env.example && rm -f .env.example && $GIT_AS commit -q -m drop-example ) >/dev/null 2>&1
run_check "$repo"
assert_fail ".env.example 不在" ".env.example がありません"

# ── git コマンドが失敗したときの stderr（失敗時だけ見せる） ────────────────────
#
# 検査が成立しなかった理由（index の破損・権限・パスの問題など）が読めないと、
# 「検査が成立していないことを合格にしない」という主題と噛み合わない。一方で
# 正常時は無音のままであること（git status / ls-files が出しうる警告を毎回見せると
# ノイズになる）も対で確認する。

it "追跡前（git status --porcelain -z）が失敗すると、git の出力が stderr へ出る"
# index を壊して git status --porcelain -z 自体を失敗させる（実測: fatal: index file ...）。
repo="$(new_repo)"
printf 'garbage' > "$repo/.git/index"
run_check "$repo"
if [[ "$CHECK_RC" -eq 0 ]]; then
  fail "落ちるべきところで通過した: $CHECK_OUT"
elif ! printf '%s' "$CHECK_OUT" | grep -q 'SECRETS_FAIL'; then
  fail "SECRETS_FAIL が出ていない: $CHECK_OUT"
elif ! printf '%s' "$CHECK_OUT" | grep -qF 'git status --porcelain -z に失敗しました'; then
  fail "既存の fatal 文言が無い: $CHECK_OUT"
elif ! printf '%s' "$CHECK_OUT" | grep -qi 'index'; then
  fail "git 側の出力（index に関する内容）が出ていない: $CHECK_OUT"
else
  pass
fi

it "追跡済み（git ls-files）が失敗すると、git の出力が stderr へ出る"
# git status --porcelain -z は成功させ、ls-files だけを失敗させるため、その呼び出し
# だけを横取りする git スタブを PATH の先頭へ置く。
repo="$(new_repo)"
fake_git_dir="$(new_workdir)/fakebin"
mkdir -p "$fake_git_dir"
real_git="$(command -v git)"
cat > "$fake_git_dir/git" <<STUB
#!/usr/bin/env bash
if [[ "\${1:-}" == "ls-files" && "\${2:-}" == "-z" ]]; then
  echo "stub: ls-files が失敗しました（permission denied を模す）" >&2
  exit 128
fi
exec "$real_git" "\$@"
STUB
chmod +x "$fake_git_dir/git"
run_check "$repo" "PATH=$fake_git_dir:$PATH"
if [[ "$CHECK_RC" -eq 0 ]]; then
  fail "落ちるべきところで通過した: $CHECK_OUT"
elif ! printf '%s' "$CHECK_OUT" | grep -q 'SECRETS_FAIL'; then
  fail "SECRETS_FAIL が出ていない: $CHECK_OUT"
elif ! printf '%s' "$CHECK_OUT" | grep -qF 'git ls-files に失敗しました'; then
  fail "既存の fatal 文言が無い: $CHECK_OUT"
elif ! printf '%s' "$CHECK_OUT" | grep -qF 'stub: ls-files が失敗しました'; then
  fail "git 側の出力（スタブのメッセージ）が出ていない: $CHECK_OUT"
else
  pass
fi

it "正常時は git の出力見出しが一切出ない（成功時は無音のまま）"
repo="$(new_repo)"
run_check "$repo"
if [[ "$CHECK_RC" -ne 0 ]]; then
  fail "通るべきところで落ちた: $CHECK_OUT"
elif printf '%s' "$CHECK_OUT" | grep -q '\[secrets\] git の出力:'; then
  fail "正常時にもかかわらず git の出力見出しが出ている（ノイズ化の回帰）: $CHECK_OUT"
else
  pass
fi

# ── CNS_PROBE（.env / .env.example のキー抽出）の fail-closed ────────────────
#
# 子シェルに set -euo pipefail が無いと、sort / comm が存在しない環境でも
# キー抽出が空のまま exit 0 で完走し、呼び出し側は終了ステータスだけを見ているため
# この経路を検出できない（.env.example の機密値検査が何も検査せずに通る）。

it "comm / sort が PATH に無い環境では落ちる（抽出が fail-closed であること）"
# check-no-secrets.sh 自身と CNS_PROBE の子 bash が必要とする外部コマンドだけを
# 通す最小 PATH を作り、comm / sort をあえて外す。command -v は関数定義を拾わない
# よう、テストランナー自身が素の bash から起動される前提に乗る。
repo="$(new_repo)"
stub="$(new_workdir)/bin"
mkdir -p "$stub"
for c in git sed grep mktemp rm bash dirname env cat; do
  ln -s "$(command -v "$c")" "$stub/$c"
done
run_check "$repo" "PATH=$stub"
if [[ "$CHECK_RC" -eq 0 ]]; then
  fail "落ちるべきところで通過した: $CHECK_OUT"
elif ! printf '%s' "$CHECK_OUT" | grep -q 'SECRETS_FAIL'; then
  fail "SECRETS_FAIL が出ていない: $CHECK_OUT"
elif ! printf '%s' "$CHECK_OUT" | grep -qF 'のキーを抽出できませんでした'; then
  fail "抽出失敗の fatal 文言が出ていない: $CHECK_OUT"
else
  pass
fi

it ".env.example に KEY=... の行があるのに抽出が 0 件なら落ちる（抽出が成立していない疑い）"
# ローダーを no-op に差し替え、「失敗はしていないが結果が空」を再現する
# （set -euo pipefail だけでは検出できない経路）。.env.example 自体は生成物のまま
# 複数の KEY= 行を持つ。
repo="$(new_repo)"
printf '#!/usr/bin/env bash\n' > "$repo/scripts/load-project-env.sh"
run_check "$repo"
if [[ "$CHECK_RC" -eq 0 ]]; then
  fail "落ちるべきところで通過した: $CHECK_OUT"
elif ! printf '%s' "$CHECK_OUT" | grep -q 'SECRETS_FAIL'; then
  fail "SECRETS_FAIL が出ていない: $CHECK_OUT"
else
  assert_contains "$CHECK_OUT" "抽出が成立していない疑い" "空抽出の検出メッセージ"
fi

it "ベースラインに無い普通のキー（MY_TOKEN）が行にあるのに抽出 0 件なら落ちる（baseline 除外の回帰）"
# .env.example を単一のベースライン外キーだけに絞り、baseline 除外そのものが
# 「何でも通す」側へ倒れていないことを固定する。上のテストは生成物由来の
# 複数キーで確認しているため、ここでは 1 キーで最小構成として確認する。
repo="$(new_repo)"
printf '#!/usr/bin/env bash\n' > "$repo/scripts/load-project-env.sh"
printf 'MY_TOKEN=\n' > "$repo/.env.example"
run_check "$repo"
if [[ "$CHECK_RC" -eq 0 ]]; then
  fail "落ちるべきところで通過した: $CHECK_OUT"
elif ! printf '%s' "$CHECK_OUT" | grep -q 'SECRETS_FAIL'; then
  fail "SECRETS_FAIL が出ていない: $CHECK_OUT"
else
  assert_contains "$CHECK_OUT" "抽出が成立していない疑い" "空抽出の検出メッセージ"
fi

it "空の .env.example（キー 0 件）では落ちない（環境変数を使わないプロジェクトは正当）"
repo="$(new_repo)"
printf '# このプロジェクトは環境変数を使わない\n' > "$repo/.env.example"
run_check "$repo"
assert_pass "空の .env.example"

it ".env.example がベースライン名（PATH 等）だけで構成されていても落ちない（誤検知の回帰）"
# CNS_PROBE は comm -13 で「ローダー実行後に増えた」名前だけを差分として拾うため、
# env -i 起動時点で既に export されている名前（PATH / HOME / LC_ALL、bash が自動で
# export する PWD / SHLVL / _ など）は原理的に検出できない。空抽出ガードの比較対象を
# 素朴な行数にすると、この構成の .env.example を「抽出が成立していない」と誤認して
# fatal になる。baseline を除いた比較にしたことで、ここは正しく通る。
repo="$(new_repo)"
printf 'PATH=/usr/bin\nHOME=/nonexistent\n' > "$repo/.env.example"
run_check "$repo"
assert_pass "ベースライン名だけの .env.example"

# ── 呼び出し元（verify.sh から直接呼ぶ） ─────────────────────────────────────

it "生成された verify.sh が check-no-secrets.sh を呼ぶ"
# acceptance.sh 雛形ではなく verify.sh から呼ぶ。acceptance.sh はプロジェクトが
# 所有・編集するため、規範由来の検査をそこへ置くと消える経路ができる。
repo="$(new_repo)"
printf '{}\n' > "$repo/credentials.json"
acc="$(new_workdir)/acc-pass.sh"; printf '#!/usr/bin/env bash\nexit 0\n' > "$acc"
if out_txt="$(cd "$repo" && VERIFY_ACCEPTANCE="$acc" bash scripts/verify.sh 2>&1)"; then
  fail "機密が混入しているのに VERIFY_PASS になった: $out_txt"
else
  assert_contains "$out_txt" "VERIFY_FAIL" "verify 出力"
fi

it "機密が無ければ verify.sh は従来どおり VERIFY_PASS"
repo="$(new_repo)"
acc="$(new_workdir)/acc-pass.sh"; printf '#!/usr/bin/env bash\nexit 0\n' > "$acc"
if out_txt="$(cd "$repo" && VERIFY_ACCEPTANCE="$acc" bash scripts/verify.sh 2>&1)"; then
  assert_contains "$out_txt" "VERIFY_PASS" "verify 出力"
else
  fail "機密が無いのに落ちた: $out_txt"
fi

exit_with_result
