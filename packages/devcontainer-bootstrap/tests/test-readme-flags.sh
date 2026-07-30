#!/usr/bin/env bash
# README のオプション記載と bootstrap.sh の引数解析が一致することを検査する。
#
# README は公開リポジトリの唯一の入口ドキュメントで、利用者はここに載っている
# フラグしか知り得ない。実装が受け付けるのに README に無いフラグは「存在しない
# 機能」になり（--dry-run / --force / --help が実際にこの状態だった）、README に
# あるのに実装が受け付けないフラグはコピペで即エラーになる。
#
# したがって差集合を **両方向** で見る。片方向だけだと、削除された実装フラグの
# 記載が README に残り続けても検出できない。
#
# 実行前提コマンドと既定値も同じ理由で機械照合する。README の記述は実装の
# require_cmd 群・変数初期化と 1 対 1 に対応していなければならない。

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-readme-flags"

README="$PKG_DIR/README.md"

# README にのみ現れてよいフラグ。実装から削除済みで、移行案内としてだけ載せる。
#
# --mode は case 文に分岐を持たず `*)` の unknown option として拒否されるため、
# 実装側の抽出には現れない。README からも消すと移行できない利用者が取り残される
# ので、ここに明示して例外扱いにする（例外は一覧にして可視化し、暗黙に増やさない）。
README_ONLY_FLAGS="--mode"

# ── 実装側のフラグ集合 ────────────────────────────────────────────────────────

# 引数解析の case 文からフラグを抽出する。テスト側に一覧を書き写すと、実装を
# 変えても気づけない（写した一覧が古くなるだけ）。
impl_flags() {
  sed -n '/^while \[\[ \$# -gt 0 \]\]; do/,/^done$/p' "$BOOTSTRAP" \
    | awk '
        # case のパターン行だけを拾う。先頭の非空白が - で始まる行が該当する。
        /^[[:space:]]*-/ {
          line = $0
          sub(/\).*$/, "", line)          # パターン部だけ残す
          gsub(/^[[:space:]]+/, "", line)
          n = split(line, a, "|")          # -h|--help のような複合パターンを分解
          for (i = 1; i <= n; i++) print a[i]
        }
      ' \
    | sort -u
}

# ── README 側のフラグ集合 ────────────────────────────────────────────────────

# 入力仕様の節（`## 入力仕様` から次の `## ` 見出しまで）を対象にする。README 全体を
# 見ると移行表や解説の言及まで拾ってしまい、「入力仕様として列挙されているか」を
# 判定できない。
readme_input_section() {
  awk '
    /^## 入力仕様/ { inside = 1; next }
    /^## / { inside = 0 }
    inside { print }
  ' "$README"
}

readme_flags() {
  readme_input_section \
    | grep -oE '`-{1,2}[a-zA-Z][a-zA-Z0-9-]*' \
    | sed 's/^`//' \
    | grep -vE -- '-$' \
    | sort -u
}

# ── 双方向の差集合 ────────────────────────────────────────────────────────────

impl_list="$(impl_flags)"
readme_list="$(readme_flags)"

it "引数解析からフラグを抽出できる"
if [[ -n "$impl_list" ]]; then pass; else fail "bootstrap.sh の case 文からフラグを抽出できなかった"; fi

it "README の入力仕様からフラグを抽出できる"
if [[ -n "$readme_list" ]]; then pass; else fail "README の入力仕様節からフラグを抽出できなかった"; fi

it "実装が受け付ける全フラグが README の入力仕様に載っている"
missing_in_readme=""
for f in $impl_list; do
  case "
$readme_list
" in
    *"
$f
"*) ;;
    *) missing_in_readme="$missing_in_readme $f" ;;
  esac
done
if [[ -z "$missing_in_readme" ]]; then
  pass
else
  fail "README の入力仕様に無い実装フラグ:$missing_in_readme"
fi

it "README が載せるフラグはすべて実装が受け付ける"
missing_in_impl=""
for f in $readme_list; do
  case " $README_ONLY_FLAGS " in *" $f "*) continue ;; esac
  case "
$impl_list
" in
    *"
$f
"*) ;;
    *) missing_in_impl="$missing_in_impl $f" ;;
  esac
done
if [[ -z "$missing_in_impl" ]]; then
  pass
else
  fail "README にあるが実装が受け付けないフラグ:$missing_in_impl"
fi

it "例外として許した README 専用フラグが実装に復活していない"
resurrected=""
for f in $README_ONLY_FLAGS; do
  case "
$impl_list
" in
    *"
$f
"*) resurrected="$resurrected $f" ;;
  esac
done
if [[ -z "$resurrected" ]]; then
  pass
else
  fail "実装が受け付けるようになったのに例外一覧に残っているフラグ:$resurrected（README_ONLY_FLAGS から外すこと）"
fi

# ── 実行前提コマンド ──────────────────────────────────────────────────────────

it "無条件の require_cmd がすべて README に列挙されている"
# トップレベル（インデント無し）の require_cmd = 起動時に必ず要求されるコマンド。
undocumented=""
for cmd in $(grep -E '^require_cmd [a-z]+$' "$BOOTSTRAP" | awk '{print $2}' | sort -u); do
  if ! grep -q "^| \`$cmd\` |" "$README"; then
    undocumented="$undocumented $cmd"
  fi
done
if [[ -z "$undocumented" ]]; then
  pass
else
  fail "README の実行前提コマンド表に無い require_cmd:$undocumented"
fi

it "URL 経路でのみ必要な tar が README に記載されている"
if grep -q '^| `tar` |' "$README"; then
  pass
else
  fail "URL ソース時に必要な tar が実行前提コマンド表に無い"
fi

it "doctor.sh の jq 依存が README に記載されている"
if grep -q 'doctor.sh` は `jq`' "$README"; then
  pass
else
  fail "doctor.sh が jq を必要とする旨が README に無い"
fi

# ── 既定値 ────────────────────────────────────────────────────────────────────

# README が「既定: …」として説明している値の実装側の出所を固定する。実装の初期化を
# 変えたら README も直す、という対応関係をテストで結ぶ。
it "README が説明する既定値が bootstrap.sh の変数初期化と一致する"
mismatch=""
for pair in 'FORCE="false"' 'DRY_RUN="false"' 'MANAGE_GITIGNORE="true"' \
            'GITIGNORE_TARGETS=""' 'PLAYBOOK_CONFLICT_POLICY="skip"'; do
  grep -Fqx -- "$pair" "$BOOTSTRAP" || mismatch="$mismatch $pair"
done
if [[ -z "$mismatch" ]]; then
  pass
else
  fail "README の既定値記述と一致しない（実装側に見つからない）初期化:$mismatch"
fi

it "--force 未指定時の温存挙動が README から読み取れる"
if grep -q 'skip (exists)' "$README"; then
  pass
else
  fail "既存ファイルを skip (exists) で温存する挙動が README に無い"
fi

# ── rust の取りこぼし ────────────────────────────────────────────────────────

it "検証ルールの対応言語に rust が含まれる"
if grep -q 'node|go|python|php|rust' "$README"; then
  pass
else
  fail "検証ルール 1 の対応言語列挙に rust が無い"
fi

it ".gitignore の暗黙ターゲット表に rust→Rust が含まれる"
if grep -q '`rust`→`Rust`' "$README"; then
  pass
else
  fail ".gitignore 暗黙ターゲットの対応表に rust→Rust が無い"
fi

# ── 対応言語の集合照合（両方向） ──────────────────────────────────────────────
#
# 個別言語の「取りこぼし」検査（下記）は、書いた言語しか守れない。言語を追加した
# ときに検査ごと足し忘れると、README の追随漏れがそのまま通る。フラグと同じく
# 実装側から一覧を生成して両方向の差集合を見る
# （規範 .ai-playbook/shared-ai-rules.md「一覧の複製は機械照合で担保する」）。

# 入力検証 case の受理集合を実装から取り出す。
impl_languages() {
  sed -n 's/^[[:space:]]*\(node|[a-z|]*\)) ;;$/\1/p' "$PKG_DIR/bootstrap.sh" \
    | head -1 | tr '|' '\n' | sort -u
}

# README「言語サポート」節の箇条書きから取り出す。節内の ### 小見出し（拡張表）は
# 箇条書きを持たないため、節末まで拾って差し支えない。
readme_languages() {
  awk '/^## 言語サポート$/{f=1;next} /^## /{f=0} f' "$README" \
    | sed -n 's/^- `\([a-z0-9]*\)`（.*$/\1/p' | sort -u
}

it "対応言語の抽出が両側で空でない（抽出ロジック自体の破損検知）"
impl_langs="$(impl_languages)"
readme_langs="$(readme_languages)"
if [[ -n "$impl_langs" && -n "$readme_langs" ]]; then
  pass
else
  fail "抽出が空: impl='$impl_langs' readme='$readme_langs'"
fi

it "実装が受理する言語はすべて README に載っている"
missing="$(comm -23 <(printf '%s\n' "$impl_langs") <(printf '%s\n' "$readme_langs"))"
if [[ -z "$missing" ]]; then pass; else fail "README に無い対応言語: $(printf '%s' "$missing" | tr '\n' ' ')"; fi

it "README に載る言語はすべて実装が受理する"
extra="$(comm -13 <(printf '%s\n' "$impl_langs") <(printf '%s\n' "$readme_langs"))"
if [[ -z "$extra" ]]; then pass; else fail "実装が受理しない言語が README にある: $(printf '%s' "$extra" | tr '\n' ' ')"; fi

# ── ruby の取りこぼし ────────────────────────────────────────────────────────

it "検証ルールの対応言語に ruby が含まれる"
if grep -q 'node|go|python|php|rust|ruby' "$README"; then
  pass
else
  fail "検証ルール 1 の対応言語列挙に ruby が無い"
fi

it ".gitignore の暗黙ターゲット表に ruby→Ruby が含まれる"
if grep -q '`ruby`→`Ruby`' "$README"; then
  pass
else
  fail ".gitignore 暗黙ターゲットの対応表に ruby→Ruby が無い"
fi

it "言語サポート節に ruby が列挙される"
if grep -q '^- `ruby`' "$README"; then
  pass
else
  fail "言語サポート節に ruby の項目が無い"
fi

it "language server 拡張表に ruby→Shopify.ruby-lsp が含まれる"
if grep -q '`Shopify.ruby-lsp`' "$README"; then
  pass
else
  fail "language server 拡張表に Shopify.ruby-lsp が無い"
fi

it "--gitignore-targets の表記例に Rust が含まれる"
if grep -q '`Rust`' "$README"; then
  pass
else
  fail "--gitignore-targets の値の例に Rust が無い"
fi

exit_with_result
