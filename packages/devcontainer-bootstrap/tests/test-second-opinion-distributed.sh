#!/usr/bin/env bash
# 第二意見レビューが、DCB が配置し配布のままのファイル（上流でレビュー済み）を指す指摘を、
# 判定に数えないことを検証する（#695）。差分は外さずそのまま渡し、依頼文には一覧を添えず、
# JSON スキーマ方式（antigravity / codex）の判定で、そのファイルを指す指摘を落とす件数に数えない。
#
# 配布のままとみなす条件: レビューする版の ORIGIN に hash: があり owned: が無く、中身の sha256 が
# 記録と一致し、状態が追加かモードの変わらない変更で、かつ (a) hash: の値が前後で同じ、または
# (b) 前の版の ORIGIN が読め、version= の行が前後で違う。
#
# 検証の仕方: antigravity の CLI（agy）を stub に差し替え、決めた JSON を返させる。
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-second-opinion-distributed"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
REVIEW="$ROOT/.ai-playbook/templates/second-opinion-review.sh"
SCHEMA="$ROOT/.ai-playbook/templates/second-opinion-schema.json"
GIT_AUTHOR='-c user.name=T -c user.email=t@example.com'
ZERO64="0000000000000000000000000000000000000000000000000000000000000000"

in_repo() { ( cd "$1" && eval "$2" ) >/dev/null 2>&1; }

sha_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'  # bsd-ok: 無ければ下の shasum へ分岐する
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# 指定した file を指す vulnerability（ゲート対象）を 1 件返す agy の stub。
mk_stub() { # bindir file
  local bindir="$1" file="$2" so
  so="{\"reviewed\":true,\"findings\":[{\"category\":\"vulnerability\",\"file\":\"$file\",\"line\":1,\"what\":\"x\",\"why\":\"y\",\"failure_scenario\":\"s\"}]}"
  mkdir -p "$bindir"
  cat > "$bindir/agy" <<STUB
#!/usr/bin/env bash
prev=""
for a in "\$@"; do
  if [[ "\$prev" == "-p" ]]; then printf '%s' "\$a" > "$bindir/.argv"; fi
  prev="\$a"
done
printf '{"conversation_id":"x","status":"SUCCESS","response":"...","structured_output":%s}\n' '$so'
STUB
  chmod +x "$bindir/agy"
}

# ORIGIN を書く。dist.sh の hash: は同じパスで 2 行（先頭の記録が正。後ろは食い違う値）。
write_origin() { # dir version
  local dir="$1"
  {
    echo "version=$2"
    echo "hash:dist.sh=$(sha_of "$dir/dist.sh")"
    echo "hash:other.sh=$(sha_of "$dir/other.sh")"
    echo "hash:owned.txt=$(sha_of "$dir/owned.txt")"
    echo "owned:owned.txt=1"
    echo "hash:dist.sh=$ZERO64"
  } > "$dir/.devcontainer/ORIGIN"
}

# c1: dist.sh（配布物）/ other.sh（別の配布物。変更しない）/ owned.txt（owned:）/ mine.txt と ORIGIN(version=1)。
# 作業ツリーの変更:
#   upgrade = 追従（dist.sh と owned.txt と mine.txt を変え、ORIGIN は version=2 と各 hash: を更新）
#   tamper  = dist.sh を手で変え、ORIGIN の hash: だけ書き換える（version= はそのまま）
#   noprev  = c1 に ORIGIN が無く、作業ツリーで初めて足す（前の版の ORIGIN が読めない）
#   none    = ORIGIN が無い
mk_repo() {
  local dir="$1" mode="${2:-upgrade}"
  mkdir -p "$dir/scripts" "$dir/.devcontainer"
  cp "$REVIEW" "$dir/scripts/second-opinion-review.sh"
  cp "$SCHEMA" "$dir/scripts/second-opinion-schema.json"
  printf 'echo base\n' > "$dir/dist.sh"
  printf 'echo other\n' > "$dir/other.sh"
  printf 'mine\n' > "$dir/mine.txt"
  printf 'owned base\n' > "$dir/owned.txt"
  case "$mode" in none|noprev) ;; *) write_origin "$dir" 1 ;; esac
  ( cd "$dir" && git init -q && git add -A && git $GIT_AUTHOR commit -q -m c1 ) >/dev/null 2>&1
  case "$mode" in
    upgrade)
      printf 'echo DISTRIBUTED_MARK\n' > "$dir/dist.sh"
      printf 'owned DISTRIBUTED_OWNED_MARK\n' > "$dir/owned.txt"
      printf 'mine changed USER_MARK\n' > "$dir/mine.txt"
      write_origin "$dir" 2 ;;
    tamper)
      printf 'echo HAND_EDITED\n' > "$dir/dist.sh"
      write_origin "$dir" 1 ;;
    noprev)
      printf 'echo DISTRIBUTED_MARK\n' > "$dir/dist.sh"
      write_origin "$dir" 2 ;;
    none)
      printf 'echo DISTRIBUTED_MARK\n' > "$dir/dist.sh" ;;
  esac
}

# 実行して REVIEW_RC / REVIEW_OUT / SEEN（CLI へ渡った依頼文）を得る。
run_review() { # dir bindir [args...]
  local dir="$1" b="$2"; shift 2
  rm -f "$b/.argv"
  REVIEW_OUT="$(cd "$dir" && PATH="$b:$PATH" bash scripts/second-opinion-review.sh --engine antigravity "$@" 2>&1)"
  REVIEW_RC=$?
  SEEN="$(cat "$b/.argv" 2>/dev/null || true)"
}

# 作業用のリポジトリ（引数: モード, 指摘の file）を作って d / b に入れ、ステージして実行する。
case_run() { # mode file [review args...]
  local mode="$1" file="$2"; shift 2
  d="$(new_workdir)/r"; b="$(new_workdir)/bin"; mk_stub "$b" "$file"; mk_repo "$d" "$mode"
  in_repo "$d" "git add -A"
  run_review "$d" "$b" "$@"
}

it "配布のままのファイルを指す vulnerability の指摘だけなら通り、[配布物・判定外] と件数が出る"
case_run upgrade dist.sh
if [[ "$REVIEW_RC" -eq 0 && "$REVIEW_OUT" == *"[配布物・判定外]"* && "$REVIEW_OUT" == *"配布のままのファイル 1 件への指摘は判定に数えません"* ]]; then pass; else fail "rc=$REVIEW_RC out=$REVIEW_OUT"; fi

it "run の行に「配布物への指摘 N 件は判定外」が出る（最後の要約の行は変わらない）"
if [[ "$REVIEW_OUT" == *"run 1/1: 配布物への指摘 1 件は判定外"* && "$REVIEW_OUT" == *"[second-opinion] LGTM ("* ]]; then pass; else fail "$REVIEW_OUT"; fi

it "差分はそのまま渡り、依頼文に一覧は添えない"
if [[ "$SEEN" == *DISTRIBUTED_MARK* && "$SEEN" == *USER_MARK* && "$SEEN" != *"配布したままのファイル"* ]]; then pass; else fail "$SEEN"; fi

it "指摘の file が a/ b/ 付き・根を前に持つ絶対パスでも一致する"
case_run upgrade a/dist.sh
rc1=$REVIEW_RC
case_run upgrade b/dist.sh
rc2=$REVIEW_RC
d="$(new_workdir)/r"; b="$(new_workdir)/bin"; mk_repo "$d" upgrade
mk_stub "$b" "$(cd "$d" && pwd -P)/dist.sh"
in_repo "$d" "git add -A"
run_review "$d" "$b"
if [[ "$rc1" -eq 0 && "$rc2" -eq 0 && "$REVIEW_RC" -eq 0 ]]; then pass; else fail "rc=$rc1,$rc2,$REVIEW_RC"; fi

it "差分に a/dist.sh（利用側のファイル）があるとき、file: a/dist.sh の指摘は判定に数える"
d="$(new_workdir)/r"; b="$(new_workdir)/bin"; mk_stub "$b" a/dist.sh; mk_repo "$d" upgrade
mkdir -p "$d/a"; printf 'mine a\n' > "$d/a/dist.sh"
in_repo "$d" "git add -A"
run_review "$d" "$b"
if [[ "$REVIEW_RC" -ne 0 && "$REVIEW_OUT" != *"[配布物・判定外]"* ]]; then pass; else fail "rc=$REVIEW_RC out=$REVIEW_OUT"; fi

it "差分に a/ のパスが無いときの file: a/dist.sh は、従来どおり判定外になる"
case_run upgrade a/dist.sh
if [[ "$REVIEW_RC" -eq 0 && "$REVIEW_OUT" == *"[配布物・判定外]"* ]]; then pass; else fail "rc=$REVIEW_RC out=$REVIEW_OUT"; fi

it "差分に無いが追跡している利用側の a/dist.sh への指摘は、判定に数える"
d="$(new_workdir)/r"; b="$(new_workdir)/bin"; mk_stub "$b" a/dist.sh; mk_repo "$d" upgrade
mkdir -p "$d/a"; printf 'mine a\n' > "$d/a/dist.sh"
in_repo "$d" "git add a/dist.sh && git $GIT_AUTHOR commit -q -m c1b a/dist.sh && git add -A"
run_review "$d" "$b"
if [[ "$REVIEW_RC" -ne 0 && "$REVIEW_OUT" != *"[配布物・判定外]"* ]]; then pass; else fail "rc=$REVIEW_RC out=$REVIEW_OUT"; fi

it "利用側の dist.sh:12 というファイルへの指摘は、判定に数える"
d="$(new_workdir)/r"; b="$(new_workdir)/bin"; mk_stub "$b" dist.sh:12; mk_repo "$d" upgrade
printf 'mine\n' > "$d/dist.sh:12"
in_repo "$d" "git add -A"
run_review "$d" "$b"
if [[ "$REVIEW_RC" -ne 0 && "$REVIEW_OUT" != *"[配布物・判定外]"* ]]; then pass; else fail "rc=$REVIEW_RC out=$REVIEW_OUT"; fi

it "バックスラッシュを含む配布物も除外される"
d="$(new_workdir)/r"; b="$(new_workdir)/bin"; mk_stub "$b" 'back\\slash.sh'; mk_repo "$d" upgrade
printf 'echo BS\n' > "$d/"'back\slash.sh'
echo "hash:back\\slash.sh=$(sha_of /dev/stdin < "$d/"'back\slash.sh')" >> "$d/.devcontainer/ORIGIN"
in_repo "$d" "git add -A"
run_review "$d" "$b"
if [[ "$REVIEW_RC" -eq 0 && "$REVIEW_OUT" == *"[配布物・判定外]"* ]]; then pass; else fail "rc=$REVIEW_RC out=$REVIEW_OUT"; fi

it "タブを含む配布物も除外される"
d="$(new_workdir)/r"; b="$(new_workdir)/bin"; mk_stub "$b" 'tab\there.sh'; mk_repo "$d" upgrade
printf 'echo TAB\n' > "$d/"$'tab\there.sh'
printf 'hash:tab\there.sh=%s\n' "$(sha_of /dev/stdin < "$d/"$'tab\there.sh')" >> "$d/.devcontainer/ORIGIN"
in_repo "$d" "git add -A"
run_review "$d" "$b"
if [[ "$REVIEW_RC" -eq 0 && "$REVIEW_OUT" == *"[配布物・判定外]"* ]]; then pass; else fail "rc=$REVIEW_RC out=$REVIEW_OUT"; fi

it "skip-worktree の印があるとき、索引の手直しを作業ツリーの記録どおりの中身で隠せない"
d="$(new_workdir)/r"; b="$(new_workdir)/bin"; mk_stub "$b" dist.sh; mk_repo "$d" upgrade
in_repo "$d" "printf 'echo HAND_EDITED\\n' > dist.sh && git add -A && git update-index --skip-worktree dist.sh && printf 'echo DISTRIBUTED_MARK\\n' > dist.sh"
run_review "$d" "$b"
if [[ "$REVIEW_RC" -ne 0 && "$REVIEW_OUT" != *"[配布物・判定外]"* ]]; then pass; else fail "rc=$REVIEW_RC out=$REVIEW_OUT"; fi

it "根の外の絶対パスや別のディレクトリの a/ は一致しない"
case_run upgrade /elsewhere/dist.sh
rc1=$REVIEW_RC
case_run upgrade sub/dist.sh
if [[ "$rc1" -ne 0 && "$REVIEW_RC" -ne 0 ]]; then pass; else fail "rc=$rc1,$REVIEW_RC"; fi

it "改行を含むパス名があっても、-z の見出しとパスの並びがずれない"
d="$(new_workdir)/r"; b="$(new_workdir)/bin"; mk_stub "$b" dist.sh; mk_repo "$d" upgrade
printf 'x\n' > "$d/"$'a\nb.sh'
in_repo "$d" "git add -A"
run_review "$d" "$b"
if [[ "$REVIEW_RC" -eq 0 && "$REVIEW_OUT" == *"[配布物・判定外]"* ]]; then pass; else fail "rc=$REVIEW_RC out=$REVIEW_OUT"; fi

it "利用側のファイルを指す指摘は、従来どおり落とす"
case_run upgrade mine.txt
if [[ "$REVIEW_RC" -ne 0 && "$REVIEW_OUT" != *"[配布物・判定外]"* ]]; then pass; else fail "rc=$REVIEW_RC out=$REVIEW_OUT"; fi

it "指摘の file が ./ 付きでも、:行番号 付きでも一致する"
case_run upgrade ./dist.sh
rc1=$REVIEW_RC
case_run upgrade dist.sh:12
if [[ "$rc1" -eq 0 && "$REVIEW_RC" -eq 0 && "$REVIEW_OUT" == *"[配布物・判定外]"* ]]; then pass; else fail "rc1=$rc1 rc=$REVIEW_RC out=$REVIEW_OUT"; fi

it "owned: のファイルを指す指摘は落とす"
case_run upgrade owned.txt
if [[ "$REVIEW_RC" -ne 0 ]]; then pass; else fail "$REVIEW_OUT"; fi

it "ORIGIN が無いときは除かない"
case_run none dist.sh
if [[ "$REVIEW_RC" -ne 0 && "$SEEN" != *"配布したままのファイル"* ]]; then pass; else fail "rc=$REVIEW_RC out=$REVIEW_OUT"; fi

it "手直しと ORIGIN のハッシュの書き換えだけ（version= は不変）では除かない"
case_run tamper dist.sh
if [[ "$REVIEW_RC" -ne 0 && "$SEEN" != *"配布したままのファイル"* ]]; then pass; else fail "rc=$REVIEW_RC out=$REVIEW_OUT"; fi

it "前の版の ORIGIN が読めないときは、(b) としない"
case_run noprev dist.sh
if [[ "$REVIEW_RC" -ne 0 && "$SEEN" != *"配布したままのファイル"* ]]; then pass; else fail "rc=$REVIEW_RC out=$REVIEW_OUT"; fi

it "現物が記録と食い違うファイルは除かない"
d="$(new_workdir)/r"; b="$(new_workdir)/bin"; mk_stub "$b" dist.sh; mk_repo "$d" upgrade
in_repo "$d" "printf 'echo HAND_EDITED\\n' > dist.sh && git add -A"
run_review "$d" "$b"
if [[ "$REVIEW_RC" -ne 0 ]]; then pass; else fail "$REVIEW_OUT"; fi

it "作業ツリーだけ記録に戻してあっても、レビューする版（索引）が違えば除かない"
d="$(new_workdir)/r"; b="$(new_workdir)/bin"; mk_stub "$b" dist.sh; mk_repo "$d" upgrade
in_repo "$d" "printf 'echo HAND_EDITED\\n' > dist.sh && git add -A && printf 'echo DISTRIBUTED_MARK\\n' > dist.sh"
run_review "$d" "$b"
if [[ "$REVIEW_RC" -ne 0 ]]; then pass; else fail "$REVIEW_OUT"; fi

it "モードだけが変わったファイルは除かない"
d="$(new_workdir)/r"; b="$(new_workdir)/bin"; mk_stub "$b" other.sh; mk_repo "$d" upgrade
in_repo "$d" "git add -A && git update-index --chmod=+x other.sh"
run_review "$d" "$b"
if [[ "$REVIEW_RC" -ne 0 && "$REVIEW_OUT" == *"配布のままのファイル 1 件"* && "$REVIEW_OUT" != *"[配布物・判定外]"* ]]; then pass; else fail "rc=$REVIEW_RC out=$REVIEW_OUT"; fi

it "core.autocrlf=true の CRLF の現物（ORIGIN のハッシュは現物のバイト列）でも除く"
d="$(new_workdir)/r"; b="$(new_workdir)/bin"; mk_stub "$b" dist.sh; mk_repo "$d" upgrade
in_repo "$d" "git config core.autocrlf true && printf 'echo DISTRIBUTED_MARK\\r\\n' > dist.sh"
write_origin "$d" 2
in_repo "$d" "git add -A"
run_review "$d" "$b"
if [[ "$REVIEW_RC" -eq 0 && "$REVIEW_OUT" == *"[配布物・判定外]"* ]]; then pass; else fail "rc=$REVIEW_RC out=$REVIEW_OUT"; fi

it "日本語を含むパスも扱える（-z で解析する）"
d="$(new_workdir)/r"; b="$(new_workdir)/bin"; mk_stub "$b" "配布/日本語.sh"; mk_repo "$d" upgrade
mkdir -p "$d/配布"; printf 'echo JP\n' > "$d/配布/日本語.sh"
echo "hash:配布/日本語.sh=$(sha_of "$d/配布/日本語.sh")" >> "$d/.devcontainer/ORIGIN"
in_repo "$d" "git add -A"
run_review "$d" "$b"
if [[ "$REVIEW_RC" -eq 0 && "$REVIEW_OUT" == *"[配布物・判定外]"* ]]; then pass; else fail "rc=$REVIEW_RC out=$REVIEW_OUT"; fi

it "version= の行を消しただけでは (b) にならない"
d="$(new_workdir)/r"; b="$(new_workdir)/bin"; mk_stub "$b" dist.sh; mk_repo "$d" upgrade
grep -v '^version=' "$d/.devcontainer/ORIGIN" > "$d/o.tmp"; mv "$d/o.tmp" "$d/.devcontainer/ORIGIN"
in_repo "$d" "git add -A"
run_review "$d" "$b"
if [[ "$REVIEW_RC" -ne 0 && "$SEEN" != *"配布したままのファイル"* ]]; then pass; else fail "rc=$REVIEW_RC out=$REVIEW_OUT"; fi

it "jq が失敗したら実行失敗として落とす（LGTM にしない）"
d="$(new_workdir)/r"; b="$(new_workdir)/bin"; mk_stub "$b" dist.sh; mk_repo "$d" upgrade
in_repo "$d" "git add -A"
real_jq="$(command -v jq)"
cat > "$b/jq" <<STUBJQ
#!/usr/bin/env bash
# def isdist を含む検査だけ失敗させる
for a in "\$@"; do case "\$a" in *isdist*) exit 3 ;; esac; done
exec "$real_jq" "\$@"
STUBJQ
chmod +x "$b/jq"
run_review "$d" "$b"
if [[ "$REVIEW_RC" -ne 0 && "$REVIEW_OUT" != *"LGTM"* ]]; then pass; else fail "rc=$REVIEW_RC out=$REVIEW_OUT"; fi

it "索引の blob と作業ツリーに差があるときは、blob でハッシュして一致を見る"
d="$(new_workdir)/r"; b="$(new_workdir)/bin"; mk_stub "$b" dist.sh; mk_repo "$d" upgrade
in_repo "$d" "git add -A && printf 'echo CRLF_WORKTREE\\r\\n' > dist.sh"
run_review "$d" "$b"
if [[ "$REVIEW_RC" -eq 0 ]]; then pass; else fail "$REVIEW_OUT"; fi

it "--range A..B / A...B / A.. / 単独のリビジョン / --base でも除く"
ok=1
for spec in "HEAD~1..HEAD" "HEAD~1...HEAD" "HEAD~1.." "HEAD~1"; do
  d="$(new_workdir)/r"; b="$(new_workdir)/bin"; mk_stub "$b" dist.sh; mk_repo "$d" upgrade
  in_repo "$d" "git add -A && git $GIT_AUTHOR commit -q -m c2"
  run_review "$d" "$b" --range "$spec"
  [[ "$REVIEW_RC" -eq 0 ]] || { ok=0; echo "range $spec: rc=$REVIEW_RC $REVIEW_OUT"; }
done
d="$(new_workdir)/r"; b="$(new_workdir)/bin"; mk_stub "$b" dist.sh; mk_repo "$d" upgrade
in_repo "$d" "git add -A"
run_review "$d" "$b" --base HEAD
[[ "$REVIEW_RC" -eq 0 ]] || { ok=0; echo "base: rc=$REVIEW_RC $REVIEW_OUT"; }
if [[ "$ok" -eq 1 ]]; then pass; else fail "除かれない形がある"; fi

exit_with_result
